// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "./CredSphereDAO.sol";

contract CredSphereTimelockController is TimelockController {
    CredSphereDAO public immutable dao;

    uint256 public constant STANDARD_DELAY = 2 days;
    uint256 public constant CRITICAL_DELAY = 7 days;
    uint256 public constant EMERGENCY_DELAY = 1 hours;

    bytes32 public constant PARAMETER_CHANGE = keccak256("PARAMETER_CHANGE");
    bytes32 public constant TREASURY_OPERATION = keccak256("TREASURY_OPERATION");
    bytes32 public constant EMERGENCY_OPERATION = keccak256("EMERGENCY_OPERATION");
    bytes32 public constant UPGRADE_OPERATION = keccak256("UPGRADE_OPERATION");
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN");

    mapping(bytes32 => uint256) public operationDelays;
    mapping(address => bool) public isBlacklisted;

    event CustomDelaySet(bytes32 indexed operationType, uint256 delay);
    event UserBlacklisted(address indexed user, string reason);
    event UserWhitelisted(address indexed user);

    error InsufficientReputation();
    error BlacklistedProposer();
    error InvalidDelay();

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin,
        address payable _dao
    ) TimelockController(minDelay, proposers, executors, admin) {
        dao = CredSphereDAO(_dao);
        operationDelays[PARAMETER_CHANGE] = STANDARD_DELAY;
        operationDelays[TREASURY_OPERATION] = CRITICAL_DELAY;
        operationDelays[EMERGENCY_OPERATION] = EMERGENCY_DELAY;
        operationDelays[UPGRADE_OPERATION] = CRITICAL_DELAY;
    }

    function scheduleWithCustomDelay(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        bytes32 operationType
    ) external onlyRole(PROPOSER_ROLE) {
        if (isBlacklisted[msg.sender]) revert BlacklistedProposer();
        if (dao.getMemberReputation(msg.sender) < 50) revert InsufficientReputation();

        uint256 customDelay = operationDelays[operationType];
        if (customDelay == 0) {
            customDelay = getMinDelay();
        }

        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        schedule(target, value, data, predecessor, salt, customDelay);

        emit CallScheduled(id, 0, target, value, data, predecessor, customDelay);
    }

    function setOperationDelay(
        bytes32 operationType,
        uint256 delay
    ) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        if (delay < 1 hours || delay > 30 days) revert InvalidDelay();
        operationDelays[operationType] = delay;
        emit CustomDelaySet(operationType, delay);
    }

    function getOperationDelay(bytes32 operationType) external view returns (uint256) {
        uint256 customDelay = operationDelays[operationType];
        return customDelay == 0 ? getMinDelay() : customDelay;
    }

    function blacklistUser(address user, string memory reason) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        isBlacklisted[user] = true;
        emit UserBlacklisted(user, reason);
    }

    function whitelistUser(address user) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        isBlacklisted[user] = false;
        emit UserWhitelisted(user);
    }
}