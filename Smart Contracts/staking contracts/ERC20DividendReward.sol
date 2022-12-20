// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BaseReward.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract ERC20DividendReward is BaseReward {

  struct User {
      uint128 debt;
      uint128 accReward;
  }

  mapping(address => User) private users;
  bool private connected;
  uint256 accPerShare;

  IERC20 public rewardToken;
  IUniswapV2Router02 public dexRouter;

  event Claimed(address indexed to, uint amount);
  event DividendReceived(string reason, uint amount, uint totalStaked);

  constructor(address _stakingContract, address _rewardToken, address _router, address owner)
    BaseReward(_stakingContract, owner) {
    rewardToken = IERC20(_rewardToken);
    dexRouter = IUniswapV2Router02(_router);
  }

  function updateWeight(address _investor, uint oldWeight, uint oldTotalWeight, uint newWeight)
    external override onlyStaking {

    User storage user = users[_investor];

    uint pending = oldWeight * accPerShare / 10**18 - user.debt;
    if (pending > 0) {
      user.accReward += uint128(pending);
    }
    user.debt = uint128(accPerShare * newWeight / 10**18);
  }

  function distribute(string memory originOfTheFunds, uint _amount) external onlyOwner whenNotPaused {
    require(_amount > 0, "Value sent should be > 0");
    require(stakingContract.isRewardContractConnected(address(this)), 'Not connected');

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
    uint amount = _claim();

    rewardToken.transfer(msg.sender, amount);
    emit Claimed(msg.sender, amount);
  }

  function compound() external whenNotPaused {
    uint amount = _claim();
    IERC20 stakingToken = IERC20(stakingContract.stakedToken());

    if (address(rewardToken) != address(stakingToken)) {
      uint balanceBefore = stakingToken.balanceOf(address(this));
      rewardToken.approve(address(dexRouter), amount);
      swapTokens(address(rewardToken), address(stakingToken), amount);
      uint balanceAfter = stakingToken.balanceOf(address(this));
      amount = balanceAfter - balanceBefore;
    }

    stakingToken.approve(address(stakingContract), amount);
    stakingContract.compound(msg.sender, uint128(amount));
  }

  function _claim() private returns (uint256 amount) {
    uint weight = stakingContract.weight(msg.sender);
    amount = weight * accPerShare / 10**18 - users[msg.sender].debt + users[msg.sender].accReward;
    require(amount > 0, "Nothing to claim");
    users[msg.sender].accReward = 0;
    users[msg.sender].debt = uint128(accPerShare * weight / 10**18);
  }

  // Can rescue the funds if needed
  function rescueFunds() external onlyOwner {
    super.rescueToken(address(rewardToken));
  }

  function swapTokens(address from, address to, uint256 amount) private {
    address[] memory _path = new address[](3);
    _path[0] = address(from);
    _path[1] = dexRouter.WETH();
    _path[2] = address(to);

    IERC20(from).approve(address(dexRouter), amount);

    dexRouter.swapExactTokensForTokens(
        amount,
        0,
        _path,
        address(this),
        block.timestamp
    );
  }
}
