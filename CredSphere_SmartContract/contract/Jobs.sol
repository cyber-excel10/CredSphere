// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./CredSphereDAO.sol";
import "./CREDToken.sol";
import "./CredentialNFT.sol";

contract Jobs is AccessControl, Pausable, ReentrancyGuard {
    CredSphereDAO public immutable dao;
    CREDToken public immutable credToken;
    CredentialNFT public immutable credentialNFT;

    struct Job {
        address employer;
        string title;
        string description;
        string skillsMetadata;
        uint256 rewardAmount;
        uint256 deadline;
        bool isActive;
        address assignedWorker;
        bool isCompleted;
    }

    uint256 public jobCount;
    mapping(uint256 => Job) public jobs;
    mapping(uint256 => address[]) public jobApplicants;
    mapping(address => uint256[]) public userJobs;

    event JobPosted(uint256 indexed jobId, address indexed employer, string title);
    event JobApplied(uint256 indexed jobId, address indexed worker);
    event JobAssigned(uint256 indexed jobId, address indexed worker);
    event JobCompleted(uint256 indexed jobId, address indexed worker);
    event JobClosed(uint256 indexed jobId);

    error NotAuthorized();
    error JobNotActive();
    error JobAlreadyAssigned();
    error InvalidJobId();
    error InsufficientFee();

    constructor(address payable _dao, address _credToken, address _credentialNFT) {
        dao = CredSphereDAO(_dao);
        credToken = CREDToken(_credToken);
        credentialNFT = CredentialNFT(_credentialNFT);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function postJob(
        string memory title,
        string memory description,
        string memory skillsMetadata,
        uint256 rewardAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        credToken.payFee(credToken.getFeeAmounts().jobFee, "Job Posting");
        jobCount++;
        jobs[jobCount] = Job({
            employer: msg.sender,
            title: title,
            description: description,
            skillsMetadata: skillsMetadata,
            rewardAmount: rewardAmount,
            deadline: deadline,
            isActive: true,
            assignedWorker: address(0),
            isCompleted: false
        });
        userJobs[msg.sender].push(jobCount);
        emit JobPosted(jobCount, msg.sender, title);
    }

    function applyForJob(uint256 jobId) external nonReentrant whenNotPaused {
        if (!jobs[jobId].isActive) revert JobNotActive();
        jobApplicants[jobId].push(msg.sender);
        userJobs[msg.sender].push(jobId);
        credToken.payReward(msg.sender, "job_application");
        emit JobApplied(jobId, msg.sender);
    }

    function assignJob(uint256 jobId, address worker) external {
        if (jobId == 0 || jobId > jobCount) revert InvalidJobId();
        if (msg.sender != jobs[jobId].employer && msg.sender != address(dao) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }
        if (!jobs[jobId].isActive) revert JobNotActive();
        if (jobs[jobId].assignedWorker != address(0)) revert JobAlreadyAssigned();
        jobs[jobId].assignedWorker = worker;
        emit JobAssigned(jobId, worker);
    }

    function completeJob(uint256 jobId) external nonReentrant {
        if (jobId == 0 || jobId > jobCount) revert InvalidJobId();
        if (msg.sender != jobs[jobId].assignedWorker) revert NotAuthorized();
        if (!jobs[jobId].isActive) revert JobNotActive();
        jobs[jobId].isCompleted = true;
        jobs[jobId].isActive = false;
        credToken.payReward(msg.sender, "job_completion");
        emit JobCompleted(jobId, msg.sender);
    }

    function closeJob(uint256 jobId) external {
        if (msg.sender != address(dao) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        if (jobId == 0 || jobId > jobCount) revert InvalidJobId();
        if (!jobs[jobId].isActive) revert JobNotActive();
        jobs[jobId].isActive = false;
        emit JobClosed(jobId);
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        if (jobId == 0 || jobId > jobCount) revert InvalidJobId();
        return jobs[jobId];
    }

    function jobExists(uint256 jobId) external view returns (bool) {
        return jobId != 0 && jobId <= jobCount && jobs[jobId].isActive;
    }

    function getJobApplicants(uint256 jobId) external view returns (address[] memory) {
        if (jobId == 0 || jobId > jobCount) revert InvalidJobId();
        return jobApplicants[jobId];
    }

    function hasApplied(uint256 jobId, address applicant) external view returns (bool) {
    if (jobId == 0 || jobId > jobCount) revert InvalidJobId();
    address[] memory applicants = jobApplicants[jobId];
    for (uint256 i = 0; i < applicants.length; i++) {
        if (applicants[i] == applicant) {
            return true;
        }
    }
    return false;
}

    function getUserJobs(address user) external view returns (uint256[] memory) {
        return userJobs[user];
    }

    function pause() external {
        if (msg.sender != address(dao) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _pause();
    }

    function unpause() external {
        if (msg.sender != address(dao) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _unpause();
    }

    // function setDaoAddress(address _daoAddress) external {
    //     if (msg.sender != address(dao) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
    // }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}