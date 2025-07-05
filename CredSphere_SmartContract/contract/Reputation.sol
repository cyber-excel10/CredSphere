// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./CREDToken.sol";
import "./CredSphereDAO.sol";
import "./Jobs.sol";

contract Reputation is AccessControl, Pausable {
    bytes32 public constant REPUTATION_MANAGER_ROLE = keccak256("REPUTATION_MANAGER_ROLE");

    CREDToken public immutable credToken;
    CredSphereDAO public dao;
    Jobs public immutable jobs;

    mapping(address => uint256) public reputationScores;
    mapping(address => mapping(uint256 => bool)) public hasReviewed;

    event ReputationUpdated(address indexed user, uint256 newScore);
    event ReviewSubmitted(address indexed reviewer, address indexed user, uint256 jobId, uint256 score);

    error NotAuthorized();
    error NotJobParticipant();
    error InvalidScore();
    error AlreadyReviewed();
    error InvalidJobId();

    constructor(address _credToken, address payable _dao, address _jobs) {
        credToken = CREDToken(_credToken);
        dao = CredSphereDAO(_dao);
        jobs = Jobs(_jobs);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REPUTATION_MANAGER_ROLE, msg.sender);
    }

    function submitReview(address user, uint256 jobId, uint256 score) external whenNotPaused {
        if (score < 1 || score > 5) revert InvalidScore();
        if (hasReviewed[msg.sender][jobId]) revert AlreadyReviewed();
        Jobs.Job memory job = jobs.getJob(jobId);
        if (jobId == 0 || !job.isActive) revert InvalidJobId();
        if (msg.sender != job.employer && !jobs.hasApplied(jobId, msg.sender)) revert NotJobParticipant();

        reputationScores[user] += score;
        hasReviewed[msg.sender][jobId] = true;

        emit ReviewSubmitted(msg.sender, user, jobId, score);
        emit ReputationUpdated(user, reputationScores[user]);

        if (address(dao) != address(0)) {
            credToken.payReward(msg.sender, "review_submission");
        }
    }

    function getReputation(address user) external view returns (uint256) {
        return reputationScores[user];
    }

    function pause() external {
        if (msg.sender != address(dao) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _pause();
    }

    function unpause() external {
        if (msg.sender != address(dao) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _unpause();
    }

    function setDaoAddress(address payable _daoAddress) external {
        if (msg.sender != address(dao) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        dao = CredSphereDAO(_daoAddress);
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}