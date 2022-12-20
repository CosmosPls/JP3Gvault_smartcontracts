// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./RewardStrategy.sol";

contract Staking is Ownable, Pausable {
    using ERC165Checker for address;

    struct User {
        uint128 staked;
        uint128 weight;
        uint32 lockedUntil;
        uint32 boost; // 50% = 5000
        bool locked;
    }

    mapping(address => User) public users;
    mapping(address => bool) public authorizedBridges;

    uint128 public totalStaked; // Used for GUI
    uint128 public totalWeight; // Used by reward pools

    uint256 public stakingLimitPerWallet;

    uint16 public lockDurationInDays;
    uint8 public lockBoostFactor;
    IERC20 public stakedToken;

    RewardStrategy[] private rewards;

    event Stacked(address indexed to, uint amount, bool locked);
    event Unstacked(address indexed to, uint amount);
    event Compound(address indexed to, uint amount, address indexed contractAddress);

    event RewardContractAdded(address reward);
    event RewardContractRemoved(address reward);

    event BridgeAdded(address bridge);
    event BridgeRemoved(address bridge);

    event UpdatedWalletBoost(address indexed to, uint32 newBoost);
    event UpdatedStakingLimit(uint256 newLimit);
    event UpdatedLockBoostFactor(uint8 boostFactor);
    event UpdatedLockDurationInDays(uint16 lockDurationInDays);

    constructor(address tokenAddr, address owner) {
      stakedToken = IERC20(payable(tokenAddr));
      _transferOwnership(owner);
      lockBoostFactor = 3;
      lockDurationInDays = 30;
      stakingLimitPerWallet = 10_000_000 ether;
    }

    function stake(uint128 amount, bool locked) external whenNotPaused {
      User storage user = users[msg.sender];

      require(user.staked + amount <= stakingLimitPerWallet, "Wallet limit");

      // Update staked
      user.staked += amount;
      totalStaked += amount;

      // Apply locking rules
      if (locked) {
        user.lockedUntil = uint32(block.timestamp + (lockDurationInDays * 1 days));
      } else {
        require(user.lockedUntil < block.timestamp, "Cannot stake unlocked");
      }

      // Calculate new weight
      uint128 newWeight = calculateWeight(user.staked, user.boost, locked);

      // Notify all registered pools
      for(uint i; i < rewards.length; i++) {
        rewards[i].updateWeight(msg.sender, user.weight, totalWeight, newWeight);
      }

      // update state
      totalWeight = totalWeight - user.weight + newWeight;
      user.weight = newWeight;
      user.locked = locked;

      // Transfer stake
      stakedToken.transferFrom(msg.sender, address(this), amount);
      emit Stacked(msg.sender, amount, locked);
    }

    function unstake(uint128 amount) external whenNotPaused {
      User storage user = users[msg.sender];

      // Checks
      require(user.lockedUntil < block.timestamp, "Still locked");

      // Update staked
      // No need to check amount since it will fail if greater than staked
      user.staked -= amount;
      totalStaked -= amount;

      uint128 newWeight = calculateWeight(user.staked, user.boost, false);

      // Notify all registered pools
      for(uint i; i < rewards.length; i++) {
        rewards[i].updateWeight(msg.sender, user.weight, totalWeight, newWeight);
      }

      // Set new weight
      totalWeight = totalWeight - user.weight + newWeight;
      user.weight = newWeight;
      user.locked = false;

      // Redeem staked tokens
      stakedToken.transfer(msg.sender, amount);
      emit Unstacked(msg.sender, amount);
    }

    function updateBoost(address userAddress, uint32 newBoost) external {
      require(newBoost <= 5000, "Boost limit");
      require(authorizedBridges[msg.sender], "Only Bridge");

      User storage user = users[userAddress];

      // Calculate new weight
      uint128 newWeight = calculateWeight(user.staked, newBoost, user.locked);

      // Notify all registered pools
      for(uint i; i < rewards.length; i++) {
        rewards[i].updateWeight(msg.sender, user.weight, totalWeight, newWeight);
      }

      totalWeight = totalWeight - user.weight + newWeight;
      user.weight = newWeight;
      user.boost = newBoost;

      emit UpdatedWalletBoost(userAddress, newBoost);
    }

    function calculateWeight(uint staked, uint boost, bool locked) private view returns (uint128) {
      if (locked) {
        return uint128((lockBoostFactor * staked * (10000 + boost)) / 10000);
      } else {
        return uint128((staked * (10000 + boost)) / 10000);
      }
    }

    function compound(address userAddress, uint128 amount) external {
      // Check only contract can call it
      bool allowed = false;
      for(uint i; i < rewards.length; i++) {
        if (address(rewards[i]) == msg.sender) {
          allowed = true;
          break;
        }
      }
      require(allowed, "Only reward");

      User storage user = users[userAddress];

      // Update staked
      user.staked += amount;
      totalStaked += amount;

      // Calculate new weight
      uint128 newWeight = calculateWeight(user.staked, user.boost, user.locked);

      // Notify all registered pools
      for(uint i; i < rewards.length; i++) {
        rewards[i].updateWeight(userAddress, user.weight, totalWeight, newWeight);
      }

      // update state
      totalWeight = totalWeight - user.weight + newWeight;
      user.weight = newWeight;

      // Transfer stake
      stakedToken.transferFrom(msg.sender, address(this), amount);
      emit Compound(userAddress, amount, msg.sender);
    }

    function balanceOf(address account) external view returns (uint256) {
      return users[account].staked;
    }

    function weight(address _investor) external view returns (uint) {
      return users[_investor].weight;
    }

    // Admin features

    function addBridge(address bridge) external onlyOwner {
      authorizedBridges[bridge] = true;
      emit BridgeAdded(bridge);
    }

    function removeBridge(address bridge) external onlyOwner {
      authorizedBridges[bridge] = false;
      emit BridgeRemoved(bridge);
    }

    function addRewardContract(address _reward) external onlyOwner {
      require(_reward.supportsInterface(type(RewardStrategy).interfaceId), "Reward interface not supported");
      for (uint i; i < rewards.length; i++) {
        if (address(rewards[i]) == _reward) {
            revert("Already added");
        }
      }
      rewards.push(RewardStrategy(_reward));
      emit RewardContractAdded(_reward);
    }

    function isRewardContractConnected(address _reward) external view returns (bool) {
      for (uint i; i < rewards.length; i++) {
        if (address(rewards[i]) == _reward) {
            return true;
        }
      }
      return false;
    }

    function removeRewardContract(address _reward) external onlyOwner {
      for (uint i; i < rewards.length; i++) {
        if (address(rewards[i]) == _reward) {
            rewards[i] = rewards[rewards.length-1];
            rewards.pop();
            emit RewardContractRemoved(_reward);
        }
      }
    }

    function updatestakingLimitPerWallet(uint256 newLimit) external onlyOwner {
      stakingLimitPerWallet = newLimit;
      emit UpdatedStakingLimit(newLimit);
    }

    function updateLockBoostFactor(uint8 _boostFactor) external onlyOwner {
      lockBoostFactor = _boostFactor;
      emit UpdatedLockBoostFactor(_boostFactor);
    }

    function updateLockDurationInDays(uint16 _boostLockInDays) external onlyOwner {
      lockDurationInDays = _boostLockInDays;
      emit UpdatedLockDurationInDays(_boostLockInDays);
    }

    // Circuit breaker
    // Can pause the contract
    function pause() external onlyOwner {
      _pause();
    }

    function unpause() external onlyOwner {
      _unpause();
    }

    // Can rescue the funds if needed
    function rescueFunds() external onlyOwner {
      stakedToken.transfer(owner(), stakedToken.balanceOf(address(this)));
    }
}