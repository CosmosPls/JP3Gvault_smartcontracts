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
        uint staked;
        uint weight;
        uint lockedUntil;
    }

    mapping(address => User) public users;

    uint public totalStaked; // Used for GUI
    uint public totalWeight; // Used by reward pools

    uint8 public boostFactor;
    uint16 public boostLockInDays;

    IERC20 public stakedToken;
    RewardStrategy[] private rewards;

    event Stacked(address to, uint amount, bool locked);
    event Unstacked(address to, uint amount);
    event RewardContractAdded(address reward);
    event RewardContractRemoved(address reward);

    event UpdatedBoostFactor(uint8 boostFactor);
    event UpdatedBoostLockInDays(uint16 boostLockInDays);

    constructor(address tokenAddr, address owner) {
      stakedToken = IERC20(payable(tokenAddr));
      _transferOwnership(owner);
      boostFactor = 3;
      boostLockInDays = 30;
    }

    function weight(address _investor) external view returns (uint) {
      return users[_investor].weight;
    }

    function stake(uint amount, bool locked) external whenNotPaused {
      User storage user = users[msg.sender];

      // Update staked
      user.staked += amount;
      totalStaked += amount;

      // Calculate new weight
      uint newWeight;
      if (locked) {
        newWeight = boostFactor * user.staked;
        user.lockedUntil = block.timestamp + boostLockInDays * 1 days;
      } else {
        require(user.lockedUntil < block.timestamp, "Cannot stake unlocked");
        newWeight = user.staked;
      }

      // Notify all registered pools
      for(uint i; i < rewards.length; i++) {
        rewards[i].updateWeight(msg.sender, user.weight, totalWeight, newWeight);
      }

      totalWeight = totalWeight - user.weight + newWeight;
      user.weight = newWeight;

      // Transfer stake
      stakedToken.transferFrom(msg.sender, address(this), amount);
      emit Stacked(msg.sender, amount, locked);
    }

    function unstake(uint amount) external whenNotPaused {
      User storage user = users[msg.sender];

      // Checks
      require(user.lockedUntil < block.timestamp, "Still locked");
      require(user.staked >= amount, "Cannot unstake more than staked");

      // Update staked
      user.staked -= amount;
      totalStaked -= amount;

      // Notify all registered pools
      for(uint i; i < rewards.length; i++) {
        rewards[i].updateWeight(msg.sender, user.weight, totalWeight, user.staked);
      }

      // Set new weight
      totalWeight = totalWeight - user.weight + user.staked;
      user.weight = user.staked;

      // Redeem staked tokens
      stakedToken.transfer(msg.sender, amount);
      emit Unstacked(msg.sender, amount);
    }

    // Admin features
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

    function removeRewardContract(address _reward) external onlyOwner {
      for (uint i; i < rewards.length; i++) {
        if (address(rewards[i]) == _reward) {
            rewards[i] = rewards[rewards.length-1];
            rewards.pop();
            emit RewardContractRemoved(_reward);
        }
      }
    }

    function updateBoostFactor(uint8 _boostFactor) external onlyOwner {
      boostFactor = _boostFactor;
      emit UpdatedBoostFactor(_boostFactor);
    }

    function updateBoostLockInDays(uint16 _boostLockInDays) external onlyOwner {
      boostLockInDays = _boostLockInDays;
      emit UpdatedBoostLockInDays(_boostLockInDays);
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