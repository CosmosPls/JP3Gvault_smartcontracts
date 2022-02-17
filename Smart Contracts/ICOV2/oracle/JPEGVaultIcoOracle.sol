// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "../IJPEGVaultIcoV2.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract JPEGVaultIcoOracle is AccessControl {
    using SafeMath for uint256;

    struct Response {
        address oracleAddress;
        address callerAddress;
        uint256 totalWeiRaised;
    }

    address payable owner;

    uint256 private randNonce = 0;
    uint256 private modulus = 1000;
    mapping(uint256 => bool) pendingRequests;
    mapping(uint256 => Response[]) requestsIdToResponse;

    uint256 noOfOracles = 0;
    uint256 THRESHOLD = 0;
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    event AddOracleEvent(address oracleAddress);
    event GetLatestWeiRaised(uint256 id, address callerAddress);
    event SetLatestWeiRaised(uint256 totalWeiRaised, address callerAddress);

    constructor(address _owner) {
        owner = payable(_owner);
        _setupRole(ADMIN_ROLE, _owner);
        _setupRole(ORACLE_ROLE, _owner);
        _setRoleAdmin(ADMIN_ROLE, bytes32(bytes20(_owner)));
        _setRoleAdmin(ORACLE_ROLE, bytes32(bytes20(_owner)));
    }

    receive() external payable {}

    function destroy() external onlyRole(ADMIN_ROLE) {
        selfdestruct(payable(owner));
    }

    function requestTotalWeiRaised() public returns (uint256) {
        randNonce++;
        uint256 id = uint256(
            keccak256(abi.encodePacked(block.difficulty, block.timestamp, msg.sender, randNonce))
        ) % modulus;
        pendingRequests[id] = true;
        emit GetLatestWeiRaised(id, msg.sender);
        return id;
    }

    function setTotalWeiRaised(
        uint256 _totalWeiRaised,
        uint256 _id,
        address _callerAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(pendingRequests[_id], "This request id not valid");
        Response memory resp;
        resp = Response(msg.sender, _callerAddress, _totalWeiRaised);
        requestsIdToResponse[_id].push(resp);
        delete pendingRequests[_id];
        delete requestsIdToResponse[_id];
        IJPEGVaultIcoV2 callerContractInstance;
        callerContractInstance = IJPEGVaultIcoV2(_callerAddress);
        callerContractInstance.updateTotalRaised(_totalWeiRaised, _id);
        emit SetLatestWeiRaised(_totalWeiRaised, _callerAddress);
    }

    function addOracle(address _oracle) external onlyRole(ADMIN_ROLE) {
        grantRole(ORACLE_ROLE, _oracle);
        noOfOracles++;
    }

    function removeOracle(address _oracle) external onlyRole(ADMIN_ROLE) {
        require(noOfOracles > 1);
        revokeRole(ORACLE_ROLE, _oracle);
    }
}
