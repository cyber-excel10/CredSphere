// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./CredSphereDAO.sol";
import "./CREDToken.sol";

contract CredentialNFT is ERC721, ERC721URIStorage, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    CredSphereDAO public immutable dao;
    CREDToken public immutable credToken;
    uint256 public totalSupply;
    string private baseURI = "https://ipfs.io/ipfs/";

    struct Credential {
        string title;
        string description;
        string skillsMetadata;
        string ipfsHash;
        uint256 issuedAt;
        bool isVerified;
        address issuer;
        uint256 expiryDate;
        string credentialType;
    }

    mapping(uint256 => Credential) private _credentials;
    mapping(address => uint256[]) private _ownerCredentials;
    mapping(string => uint256) private _credentialTypeCounts;
    mapping(address => bool) public isBlacklisted;

    event CredentialMinted(address indexed to, uint256 indexed tokenId, string title);
    event CredentialVerified(uint256 indexed tokenId, address indexed verifier);
    event CredentialRevoked(uint256 indexed tokenId, string reason);
    event UserBlacklisted(address indexed user, string reason);
    event UserWhitelisted(address indexed user);

    error CredentialNotExists();
    error NotAuthorized();
    error BlacklistedUser();
    error InvalidCredentialType();
    error AlreadyVerified();
    error InvalidMetadata();

    constructor(address payable _dao, address _credToken) ERC721("CredSphereNFT", "CSNFT") {
        dao = CredSphereDAO(_dao);
        credToken = CREDToken(_credToken);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
        totalSupply = 0;
    }

    function mintCredential(
        address to,
        string memory title,
        string memory description,
        string memory skillsMetadata,
        string memory ipfsHash
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (isBlacklisted[to] || isBlacklisted[msg.sender]) revert BlacklistedUser();
        if (!hasRole(MINTER_ROLE, msg.sender)) revert NotAuthorized();
        if (bytes(title).length == 0 || bytes(skillsMetadata).length == 0 || bytes(ipfsHash).length == 0) revert InvalidMetadata();

        totalSupply++;
        uint256 tokenId = totalSupply;
        string memory credentialType = _inferCredentialType(skillsMetadata);

        _credentials[tokenId] = Credential({
            title: title,
            description: description,
            skillsMetadata: skillsMetadata,
            ipfsHash: ipfsHash,
            issuedAt: block.timestamp,
            isVerified: false,
            issuer: msg.sender,
            expiryDate: 0,
            credentialType: credentialType
        });

        _safeMint(to, tokenId);
        _setTokenURI(tokenId, _credentials[tokenId].ipfsHash);
        _ownerCredentials[to].push(tokenId);
        _credentialTypeCounts[credentialType]++;

        if (address(dao) != address(0)) {
            credToken.payReward(to, "credential_mint");
        }

        emit CredentialMinted(to, tokenId, title);
        return tokenId;
    }

    function verifyCredential(uint256 tokenId) external {
        if (_ownerOf(tokenId) == address(0)) revert CredentialNotExists();
        if (msg.sender != address(dao) && !hasRole(VERIFIER_ROLE, msg.sender)) revert NotAuthorized();
        if (_credentials[tokenId].isVerified) revert AlreadyVerified();

        _credentials[tokenId].isVerified = true;
        emit CredentialVerified(tokenId, msg.sender);

        if (address(dao) != address(0)) {
            credToken.payReward(msg.sender, "credential_verification");
        }
    }

    function revokeCredential(uint256 tokenId, string memory reason) external {
        if (_ownerOf(tokenId) == address(0)) revert CredentialNotExists();
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && msg.sender != _credentials[tokenId].issuer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotAuthorized();
        }

        _credentials[tokenId].isVerified = false;
        _credentials[tokenId].expiryDate = block.timestamp;
        _removeFromOwnerCredentials(owner, tokenId);
        _credentialTypeCounts[_credentials[tokenId].credentialType]--;
        _burn(tokenId);

        emit CredentialRevoked(tokenId, reason);
    }

    function setExpiryDate(uint256 tokenId, uint256 expiryDate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ownerOf(tokenId) == address(0)) revert CredentialNotExists();
        _credentials[tokenId].expiryDate = expiryDate;
    }

    function isCredentialValid(uint256 tokenId) public view returns (bool) {
        return _ownerOf(tokenId) != address(0) &&
               _credentials[tokenId].isVerified &&
               (_credentials[tokenId].expiryDate == 0 || _credentials[tokenId].expiryDate > block.timestamp);
    }

    function getCredential(uint256 tokenId) external view returns (Credential memory) {
        if (_ownerOf(tokenId) == address(0)) revert CredentialNotExists();
        return _credentials[tokenId];
    }

    function getUserCredentials(address user) external view returns (uint256[] memory) {
        return _ownerCredentials[user];
    }

    function getCredentialTypeCount(string memory credentialType) external view returns (uint256) {
        return _credentialTypeCounts[credentialType];
    }

    function setBaseURI(string memory newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(newBaseURI).length == 0) revert InvalidMetadata();
        baseURI = newBaseURI;
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert CredentialNotExists();
        return string(abi.encodePacked(
            baseURI,
            _credentials[tokenId].ipfsHash,
            "?title=",
            _credentials[tokenId].title,
            "&type=",
            _credentials[tokenId].credentialType
        ));
    }

    function _inferCredentialType(string memory skillsMetadata) internal pure returns (string memory) {
        bytes32 typeHash = keccak256(bytes(skillsMetadata));
        if (typeHash == keccak256("education")) return "education";
        if (typeHash == keccak256("experience")) return "experience";
        if (typeHash == keccak256("skill")) return "skill";
        return "certification";
    }

    function _removeFromOwnerCredentials(address owner, uint256 tokenId) internal {
        uint256[] storage ownerTokens = _ownerCredentials[owner];
        for (uint256 i = 0; i < ownerTokens.length; i++) {
            if (ownerTokens[i] == tokenId) {
                ownerTokens[i] = ownerTokens[ownerTokens.length - 1];
                ownerTokens.pop();
                break;
            }
        }
    }

    function blacklistUser(address user, string memory reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isBlacklisted[user] = true;
        emit UserBlacklisted(user, reason);
    }

    function whitelistUser(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isBlacklisted[user] = false;
        emit UserWhitelisted(user);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _update(address to, uint256 tokenId, address auth) internal override(ERC721) returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            _removeFromOwnerCredentials(from, tokenId);
            _ownerCredentials[to].push(tokenId);
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}