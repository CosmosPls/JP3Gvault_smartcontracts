// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import "./RewardStrategy.sol";
import "./Staking.sol";

abstract contract BaseReward is RewardStrategy, Ownable, Pausable, ERC165 {

  Staking public stakingContract;

  constructor(address _stakingContract, address owner) {
    stakingContract = Staking(_stakingContract);
    _transferOwnership(owner);
  }

  modifier onlyStaking() {
    require(msg.sender == address(stakingContract), "Only staking");
    _;
  }

  function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
      //bytes4(keccak256('updateWeight(address,uint,uint,uint)'));
      return super.supportsInterface(interfaceId) ||
              interfaceId == type(RewardStrategy).interfaceId;
  }

  function rescueToken(address token) public onlyOwner {
    IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
  }

  // Circuit breaker
  // Can pause the contract
  function pause() external onlyOwner {
    _pause();
  }

  function unpause() external onlyOwner {
    _unpause();
  }
}