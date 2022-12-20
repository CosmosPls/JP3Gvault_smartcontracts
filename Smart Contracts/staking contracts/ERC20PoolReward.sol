// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BaseReward.sol";

contract ERC20PoolReward is BaseReward {

    struct User {
        uint debt;
        uint accReward;
        uint claimed;
    }
    string public constant rewardStrategy = "ER20PoolReward";

    IERC20 public token;
    uint public totalAmount;
    uint public startDate;
    uint public endDate;

    mapping(address => User) private users;
    uint private accPerShare;
    uint private lastUpdate;
    uint private tokenPerSecond;

    event Claimed(address indexed to, uint amount);
    event Distribute(address _token, uint _amount, uint _startDate, uint _endDate);

    constructor(address _stakingContract, address owner)
      BaseReward(_stakingContract, owner) {
    }

    function distribute(address _token, uint _amount, uint _startDate, uint _endDate) external onlyOwner {
      require(totalAmount == 0, "Only once");
      require(_amount > 0, "Invalid amount");
      require(_endDate > _startDate, "End < Start");
      require(block.timestamp <= _startDate, "Now > Start");
      require(stakingContract.isRewardContractConnected(address(this)), 'Not connected');

      token = IERC20(_token);
      totalAmount = _amount;
      startDate = _startDate;
      endDate = _endDate;
      tokenPerSecond = totalAmount * 10**18 / (endDate - startDate);

      token.transferFrom(msg.sender, address(this), _amount);
      emit Distribute(_token, _amount, _startDate, _endDate);
    }

    function claimable(address _investor) public view returns (uint _amount) {
      User memory user = users[_investor];
      return _reward(stakingContract.weight(_investor)) - user.debt + user.accReward - user.claimed;
    }

    function claim() external whenNotPaused {
      uint _claimable = claimable(msg.sender) ;
      if (_claimable > 0){
        token.transfer(msg.sender, _claimable);
        users[msg.sender].claimed += _claimable;
      }
      emit Claimed(msg.sender, _claimable);
    }

    function compound() external whenNotPaused {
      uint _claimable = claimable(msg.sender) ;
      if (_claimable > 0){
        require(address(token) == address(stakingContract.stakedToken()), "Same tokens");
        token.approve(address(stakingContract), _claimable);
        stakingContract.compound(msg.sender, uint128(_claimable));
        users[msg.sender].claimed += _claimable;
      }
    }

    function updateWeight(address _investor, uint oldWeight, uint oldTotalWeight, uint newWeight)
      external override onlyStaking {

      if (startDate == 0) return;

      uint _now = block.timestamp;
      if (_now < startDate) return;

      User storage user = users[_investor];

      // Store pending rewards
      uint pending = _reward(oldWeight) - user.debt;
      if (pending > 0) {
        user.accReward += pending;
      }

      // Update accumulator
      uint _lastUpdate = lastUpdate == 0 ? startDate : lastUpdate;
      lastUpdate = _now;
      uint _end = _now > endDate ? endDate : _now;
      if (_lastUpdate < _end && oldTotalWeight > 0) {
        accPerShare += tokenPerSecond * (_end - _lastUpdate) / oldTotalWeight;
      }

      // Update users debt
      user.debt = _reward(newWeight);
    }

    function _reward(uint weight) internal view returns (uint _amount) {
      uint _now = block.timestamp;
      if (_now < startDate || startDate == 0) return 0;
      uint _end = _now > endDate ? endDate : _now;
      uint _lastUpdate = lastUpdate == 0 ? startDate : lastUpdate;

      uint _accPerShare = accPerShare;
      if (_lastUpdate < _end) {
        uint _weight = stakingContract.totalWeight();
        if (_weight > 0) _accPerShare += tokenPerSecond * (_end - _lastUpdate) / _weight;
      }

      return _accPerShare * weight / 10**18;
    }

    // Can rescue the funds if needed
    function rescueFunds() external onlyOwner {
      super.rescueToken(address(token));
    }
}