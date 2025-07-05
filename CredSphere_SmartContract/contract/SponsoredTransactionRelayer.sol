// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {CREDToken} from "./CREDToken.sol";
import {CredSphereDAO} from "./CredSphereDAO.sol";

/// @title SponsoredTransactionRelayer
/// @notice Facilitates gasless transactions by allowing sponsors to pay for user transactions
contract SponsoredTransactionRelayer is AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using ECDSA for bytes32;

    bytes32 public constant SPONSOR_ROLE = keccak256("SPONSOR_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    CREDToken public immutable credToken;
    CredSphereDAO public immutable dao;

    struct SponsoredTransaction {
        address from;
        address to;
        uint256 value;
        bytes data;
        uint256 nonce;
        uint256 gasLimit;
        uint256 gasPrice;
        uint256 deadline;
        bytes signature;
    }

    bytes32 private constant SPONSORED_TX_TYPEHASH = keccak256(
        "SponsoredTransaction(address from,address to,uint256 value,bytes data,uint256 nonce,uint256 gasLimit,uint256 gasPrice,uint256 deadline)"
    );

    address[] public activeSponsors;
    mapping(address => uint256) public sponsorBalances;
    mapping(address => bool) public isActiveSponsor;
    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public nonces;

    uint256 public constant MIN_SPONSOR_DEPOSIT = 1 ether;
    uint256 public constant MAX_GAS_LIMIT = 500000;
    uint256 public constant MAX_TX_VALUE = 10 ether;
    uint256 public constant MIN_DAO_REPUTATION = 50;

    uint256 public baseFee = 0.001 ether;
    uint256 public gasMarkup = 110;
    uint256 public credFee = 1 * 10**18;
    uint256 public lastSponsorIndex;

    event TransactionSponsored(address indexed sponsor, address indexed user, bytes32 indexed txHash, uint256 gasUsed);
    event SponsorAdded(address indexed sponsor, uint256 depositAmount);
    event SponsorRemoved(address indexed sponsor, uint256 refundAmount);

    error InvalidSponsor();
    error InsufficientSponsorBalance();
    error InsufficientCRED();
    error InvalidTransaction();
    error BlacklistedUser();
    error InsufficientReputation();
    error NoAvailableSponsor();

    constructor(address _credToken, address payable _dao) EIP712("SponsoredTransactionRelayer", "1") {
        credToken = CREDToken(_credToken);
        dao = CredSphereDAO(_dao);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RELAYER_ROLE, msg.sender);
    }

    /// @notice Add a sponsor with deposit
    function addSponsor(address sponsor) external payable onlyRole(DEFAULT_ADMIN_ROLE) {
        if (sponsor == address(0)) revert InvalidSponsor();
        if (msg.value < MIN_SPONSOR_DEPOSIT) revert InsufficientSponsorBalance();
        if (isActiveSponsor[sponsor]) revert InvalidSponsor();
        if (isBlacklisted[sponsor]) revert BlacklistedUser();
        if (dao.getMemberReputation(sponsor) < MIN_DAO_REPUTATION) revert InsufficientReputation();

        isActiveSponsor[sponsor] = true;
        sponsorBalances[sponsor] += msg.value;
        activeSponsors.push(sponsor);

        emit SponsorAdded(sponsor, msg.value);
    }

    /// @notice Execute sponsored transaction - Optimized to avoid stack too deep
    function executeSponsoredTransaction(
        SponsoredTransaction memory txn
    ) external nonReentrant onlyRole(RELAYER_ROLE) whenNotPaused {
        // Validate transaction and user
        _validateTransactionAndUser(txn);
        
        // Verify signature
        _verifySignature(txn);
        
        // Process payment and find sponsor
        address sponsor = _processPaymentAndFindSponsor(txn);
        
        // Execute the actual transaction
        _executeTransaction(txn, sponsor);
    }

    /// @notice Validate transaction and user (extracted to reduce stack depth)
    function _validateTransactionAndUser(SponsoredTransaction memory txn) internal view {
        if (isBlacklisted[txn.from]) revert BlacklistedUser();
        if (txn.from == address(0) || txn.to == address(0)) revert InvalidTransaction();
        if (txn.deadline < block.timestamp) revert InvalidTransaction();
        if (txn.nonce != nonces[txn.from]) revert InvalidTransaction();
        if (txn.gasLimit > MAX_GAS_LIMIT) revert InvalidTransaction();
        if (txn.value > MAX_TX_VALUE) revert InvalidTransaction();
        if (txn.gasPrice == 0) revert InvalidTransaction();
    }

    /// @notice Verify transaction signature (extracted to reduce stack depth)
    function _verifySignature(SponsoredTransaction memory txn) internal view {
        bytes32 structHash = keccak256(abi.encode(
            SPONSORED_TX_TYPEHASH,
            txn.from,
            txn.to,
            txn.value,
            keccak256(txn.data),
            txn.nonce,
            txn.gasLimit,
            txn.gasPrice,
            txn.deadline
        ));

        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = hash.recover(txn.signature);
        if (signer != txn.from) revert InvalidTransaction();
    }

    /// @notice Process CRED payment and find sponsor (extracted to reduce stack depth)
    function _processPaymentAndFindSponsor(SponsoredTransaction memory txn) internal returns (address) {
        // Check CRED balance and pay fee
        if (credToken.balanceOf(txn.from) < credFee) revert InsufficientCRED();
        credToken.payFee(credFee, "sponsored_transaction");

        // Calculatation of required amount and find sponsor
        uint256 requiredAmount = (txn.gasLimit * txn.gasPrice * gasMarkup) / 100 + txn.value + baseFee;
        address sponsor = _findAvailableSponsor(requiredAmount);
        if (sponsor == address(0)) revert NoAvailableSponsor();

        return sponsor;
    }

    /// @notice Execute the actual transaction (extracted to reduce stack depth)
    function _executeTransaction(SponsoredTransaction memory txn, address sponsor) internal {
        nonces[txn.from]++;

        // Calculate and deduct estimated cost
        uint256 estimatedCost = (txn.gasLimit * txn.gasPrice * gasMarkup) / 100 + txn.value + baseFee;
        sponsorBalances[sponsor] -= estimatedCost;

        // Execute transaction and measure gas
        uint256 gasStart = gasleft();
        (bool success, bytes memory returnData) = txn.to.call{value: txn.value, gas: txn.gasLimit}(txn.data);
        uint256 gasUsed = gasStart - gasleft();

        // Refund unused gas to sponsor
        uint256 actualCost = (gasUsed * txn.gasPrice * gasMarkup) / 100 + txn.value + baseFee;
        if (estimatedCost > actualCost) {
            sponsorBalances[sponsor] += (estimatedCost - actualCost);
        }

        // Emit event
        bytes32 txHash = keccak256(abi.encode(txn.from, txn.to, txn.nonce, block.timestamp));
        emit TransactionSponsored(sponsor, txn.from, txHash, gasUsed);

        // Handle transaction failure
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    /// @notice Find available sponsor - Fixed to avoid infinite loops
    function _findAvailableSponsor(uint256 requiredAmount) internal returns (address) {
        if (activeSponsors.length == 0) return address(0);

        // Use simple for loop to avoid stack issues
        for (uint256 i = 0; i < activeSponsors.length; i++) {
            uint256 index = (lastSponsorIndex + i) % activeSponsors.length;
            address sponsor = activeSponsors[index];

            if (_isSponsorEligible(sponsor, requiredAmount)) {
                lastSponsorIndex = (index + 1) % activeSponsors.length;
                return sponsor;
            }
        }
        
        return address(0);
    }

    /// @notice Check if sponsor is eligible (extracted to reduce complexity)
    function _isSponsorEligible(address sponsor, uint256 requiredAmount) internal view returns (bool) {
        return isActiveSponsor[sponsor] &&
               sponsorBalances[sponsor] >= requiredAmount &&
               !isBlacklisted[sponsor] &&
               dao.getMemberReputation(sponsor) >= MIN_DAO_REPUTATION;
    }

    /// @notice Remove sponsor and refund balance
    function removeSponsor(address sponsor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isActiveSponsor[sponsor]) revert InvalidSponsor();
        
        uint256 refundAmount = sponsorBalances[sponsor];
        isActiveSponsor[sponsor] = false;
        sponsorBalances[sponsor] = 0;

        for (uint256 i = 0; i < activeSponsors.length; i++) {
            if (activeSponsors[i] == sponsor) {
                activeSponsors[i] = activeSponsors[activeSponsors.length - 1];
                activeSponsors.pop();
                break;
            }
        }

        // Refund
        if (refundAmount > 0) {
            (bool success, ) = sponsor.call{value: refundAmount}("");
            if (!success) revert("Refund failed");
        }

        emit SponsorRemoved(sponsor, refundAmount);
    }

    /// @notice Top up sponsor balance
    function topUpSponsor(address sponsor) external payable {
        if (!isActiveSponsor[sponsor]) revert InvalidSponsor();
        if (msg.value == 0) revert("Invalid amount");
        
        sponsorBalances[sponsor] += msg.value;
    }

    /// @notice Update fees
    function updateFees(uint256 newBaseFee, uint256 newGasMarkup, uint256 newCredFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGasMarkup < 100 || newGasMarkup > 200) revert("Invalid gas markup");
        
        baseFee = newBaseFee;
        gasMarkup = newGasMarkup;
        credFee = newCredFee;
    }

    /// @notice Get sponsor balance
    function getSponsorBalance(address sponsor) external view returns (uint256) {
        return sponsorBalances[sponsor];
    }

    /// @notice Get user nonce
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /// @notice Blacklist user
    function blacklistUser(address user, string memory reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isBlacklisted[user] = true;
        
        if (isActiveSponsor[user]) {
            isActiveSponsor[user] = false;
            sponsorBalances[user] = 0;
        }
    }

    /// @notice Whitelist user
    function whitelistUser(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isBlacklisted[user] = false;
    }

    /// @notice Pause contract
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdraw
    function emergencyWithdraw() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert("No balance to withdraw");
        
        (bool success, ) = msg.sender.call{value: balance}("");
        if (!success) revert("Withdrawal failed");
    }

    receive() external payable {}
}



