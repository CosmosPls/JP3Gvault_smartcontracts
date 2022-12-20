// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface RewardStrategy is IERC165 {
    function updateWeight(address _investor, uint oldWeight, uint oldTotalWeight, uint newWeight) external;
}