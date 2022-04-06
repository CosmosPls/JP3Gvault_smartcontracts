// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BaseReward.sol";

contract ERC20DividendReward is BaseReward {

    struct User {
        uint debt;
        uint accReward;
    }

    string public constant rewardStrategy = "ERC20DividendReward";

    mapping(address => User) private users;

    uint accPerShare;

    IERC20 public rewardToken;

    event Claimed(address to, uint amount);
    event DividendReceived(string reason, uint amount, uint totalStaked);

    constructor(address _stakingContract, address _rewardToken, address owner)
      BaseReward(_stakingContract, owner) {
        rewardToken = IERC20(_rewardToken);
    }

    function updateWeight(address _investor, uint oldWeight, uint oldTotalWeight, uint newWeight)
      external override onlyStaking {

      User storage user = users[_investor];

      uint pending = oldWeight * accPerShare / 10**18 - user.debt;
      if (pending > 0) {
        user.accReward += pending;
      }
      user.debt = accPerShare * newWeight / 10**18;
    }

    function distribute(string memory originOfTheFunds, uint _amount) external onlyOwner whenNotPaused {
      require(_amount > 0, "Value sent should be > 0");

      uint totalWeight = stakingContract.totalWeight();
      require(totalWeight > 0, "Total Weight should be > 0");

      accPerShare += _amount * 10**18 / totalWeight;

      rewardToken.transferFrom(msg.sender, address(this), _amount);
      emit DividendReceived(originOfTheFunds, _amount, totalWeight);
    }

    function claimable(address _investor) external view returns (uint amount) {
        amount = stakingContract.weight(_investor) * accPerShare / 10**18 - users[_investor].debt + users[_investor].accReward;
    }

    function claim() external whenNotPaused {
      uint weight = stakingContract.weight(msg.sender);
      uint amount = weight * accPerShare / 10**18 - users[msg.sender].debt + users[msg.sender].accReward;
      require(amount > 0, "Nothing to claim");
      users[msg.sender].accReward = 0;
      users[msg.sender].debt = accPerShare * weight / 10**18;

      rewardToken.transfer(msg.sender, amount);
      emit Claimed(msg.sender, amount);
    }

    // Can rescue the funds if needed
    function rescueFunds() external onlyOwner {
      rewardToken.transfer(owner(), rewardToken.balanceOf(address(this)));
    }
}