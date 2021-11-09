// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./JPEGVaultToken.sol";

contract RedistributionContract is ReentrancyGuard, Ownable {
    using SafeMath for uint;

    struct Redistribution {
        uint id;
        uint idSnapshot;
        uint amount;
        uint date;
        uint supplyHolders;
    }

    Redistribution[] redistributions;
    mapping(address => uint) private lastRedistributionClaimed;

    JPEGvaultDAOToken private token;

    constructor(address tokenAddr) {
        token = JPEGvaultDAOToken(payable(tokenAddr));
    }

    function create(uint amount) public onlyOwner nonReentrant {
        uint newSnapshotId;
        uint supplyHolders;

        (newSnapshotId, supplyHolders) = token.createRedistribution();

        Redistribution memory redistribution = Redistribution(
            redistributions.length,
            newSnapshotId,
            amount,
            block.timestamp,
            supplyHolders
        );

        token.transferFrom(msg.sender, address(this), amount);
        
        redistributions.push(redistribution);
    }

    function claim() public nonReentrant returns (bool) {
        require(lastRedistributionClaimed[msg.sender] != redistributions.length, "No token to claim");
        uint amountClaimed = 0;
        
        for (uint i = lastRedistributionClaimed[msg.sender]; i < redistributions.length; i++) {
            Redistribution memory redistribution = redistributions[i];
            amountClaimed += (redistribution.amount * token.balanceOfAt(msg.sender, redistribution.idSnapshot)) / redistribution.supplyHolders;
        }
        
        if (amountClaimed == 0) return false;
        
        token.transfer(msg.sender, amountClaimed);
        
        lastRedistributionClaimed[msg.sender] = redistributions.length;
        
        return true;
    }
    
    function get(uint id) public view returns (Redistribution memory) {
        return redistributions[id];
    }

    function getClaimable(address _investor) public returns (uint) {
        uint amountClaimed = 0;
        
        for (uint i = lastRedistributionClaimed[_investor]; i < redistributions.length; i++) {
            Redistribution memory redistribution = redistributions[i];
            amountClaimed += (redistribution.amount * token.balanceOfAt(_investor, redistribution.idSnapshot)) / redistribution.supplyHolders;
        }

        return amountClaimed;
    }
}