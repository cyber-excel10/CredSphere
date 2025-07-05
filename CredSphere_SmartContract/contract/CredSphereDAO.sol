// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "./CREDToken.sol";
import "./Jobs.sol";
import "./Reputation.sol";
import "./CredentialNFT.sol";

contract CredSphereDAO is Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes {
    Jobs public immutable jobsContract;
    CredentialNFT public immutable credentialNFT;
    CREDToken public immutable credToken;
    Reputation public immutable reputation;
    
    event JobVerificationProposed(uint256 indexed proposalId, uint256 indexed jobId);
    
    constructor(
        CREDToken _token,
        Jobs _jobsContract,
        CredentialNFT _credentialNFT,
        Reputation _reputation
    )
        Governor("CredSphereDAO")
        GovernorSettings(86400, 604800, 1000 * 10**18)
        GovernorVotes(_token)
    {
        credToken = _token;
        jobsContract = _jobsContract;
        credentialNFT = _credentialNFT;
        reputation = _reputation;
    }
    
    function proposeJobVerification(uint256 jobId, string memory description) external returns (uint256) {
        require(jobsContract.jobExists(jobId), "Job does not exist");
        require(credToken.balanceOf(msg.sender) >= 1000 * 10**18, "Insufficient stake");
        
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        
        targets[0] = address(jobsContract);
        calldatas[0] = abi.encodeWithSelector(Jobs.assignJob.selector, jobId, msg.sender);
        
        uint256 proposalId = propose(targets, values, calldatas, description);
        emit JobVerificationProposed(proposalId, jobId);
        return proposalId;
    }
    
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }
    
    function quorum(uint256) public view override returns (uint256) {
        return credToken.totalSupply() / 100;
    }
    
    function getMemberReputation(address member) external view returns (uint256) {
        return reputation.getReputation(member);
    }
}






