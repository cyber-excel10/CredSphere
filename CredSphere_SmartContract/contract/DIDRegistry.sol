// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./CredSphereDAO.sol";

/// @title DIDRegistry
/// @notice Manages Decentralized Identifiers (DIDs) as ERC721 NFTs, integrated with CredSphereDAO for reputation checks.
contract DIDRegistry is ERC721, ERC721URIStorage, Ownable, ReentrancyGuard {
    // DID profile information.
    struct DIDProfile {
        string name;
        string bio;
        string avatarURI;
        string coverPhotoURI;
        string socialLinks;
        uint256 createdAt;
        bool isActive;
    }

    event DIDCreated(uint256 indexed tokenId, address indexed owner, string name);
    event ProfileUpdated(uint256 indexed tokenId, address indexed owner);
    event DIDDeactivated(uint256 indexed tokenId, address indexed owner);
    event UserBlacklisted(address indexed user, string reason);
    event UserWhitelisted(address indexed user);

    error AlreadyHasDID();
    error NotDIDOwner();
    error DIDNotExists();
    error InvalidProfile();
    error BlacklistedUser();
    error InsufficientReputation();

    uint256 public totalSupply;
    CredSphereDAO public immutable dao;
    string private baseURI = "https://ipfs.io/ipfs/";

    mapping(uint256 => DIDProfile) private _profiles;
    mapping(address => uint256[]) private _ownerToDIDs;
    mapping(address => bool) private _hasDID;
    mapping(address => bool) public isBlacklisted;
    
    /// @notice Initializes the contract with DAO address and ERC721 metadata.
    /// @param _dao Address of the CredSphereDAO contract.
    constructor(address _dao) ERC721("CredSphere DID", "CSDID") Ownable(msg.sender) {
        require(_dao != address(0), "Invalid DAO address");
        dao = CredSphereDAO(payable(_dao));
        totalSupply = 0;
    }

    /// @notice Internal function to check if a token exists
    /// @param tokenId The token ID to check
    /// @return True if the token exists
    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Creates a DID NFT for the caller, requiring sufficient reputation.
    /// @param name Name for the DID profile.
    /// @param bio Biography for the DID profile.
    /// @param avatarURI URI for the avatar image.
    /// @param coverPhotoURI URI for the cover photo.
    /// @param socialLinks Social media links.
    /// @return tokenId The ID of the minted DID NFT.
    function createDID(
        string memory name,
        string memory bio,
        string memory avatarURI,
        string memory coverPhotoURI,
        string memory socialLinks
    ) external nonReentrant returns (uint256) {
        if (isBlacklisted[msg.sender]) revert BlacklistedUser();
        if (dao.getMemberReputation(msg.sender) < 50) revert InsufficientReputation();
        if (_hasDID[msg.sender]) revert AlreadyHasDID();
        if (bytes(name).length == 0) revert InvalidProfile();

        totalSupply++;
        uint256 tokenId = totalSupply;

        _safeMint(msg.sender, tokenId);

        _profiles[tokenId] = DIDProfile({
            name: name,
            bio: bio,
            avatarURI: avatarURI,
            coverPhotoURI: coverPhotoURI,
            socialLinks: socialLinks,
            createdAt: block.timestamp,
            isActive: true
        });

        _ownerToDIDs[msg.sender].push(tokenId);
        _hasDID[msg.sender] = true;

        emit DIDCreated(tokenId, msg.sender, name);
        return tokenId;
    }

    /// @notice Updates the profile of a DID NFT.
    /// @param tokenId ID of the DID NFT.
    /// @param profile New profile data.
    function updateProfile(uint256 tokenId, DIDProfile memory profile) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotDIDOwner();
        if (!_profiles[tokenId].isActive) revert DIDNotExists();
        if (bytes(profile.name).length == 0) revert InvalidProfile();

        profile.createdAt = _profiles[tokenId].createdAt;
        profile.isActive = _profiles[tokenId].isActive;
        _profiles[tokenId] = profile;

        emit ProfileUpdated(tokenId, msg.sender);
    }

    /// @notice Retrieves the profile of a DID NFT.
    /// @param tokenId ID of the DID NFT.
    /// @return Profile data.
    function getProfile(uint256 tokenId) external view returns (DIDProfile memory) {
        if (!_tokenExists(tokenId)) revert DIDNotExists();
        return _profiles[tokenId];
    }

    /// @notice Retrieves all DID NFTs owned by an address.
    /// @param owner Address of the owner.
    /// @return Array of DID token IDs.
    function getDIDsByOwner(address owner) external view returns (uint256[] memory) {
        return _ownerToDIDs[owner];
    }

    /// @notice Checks if an address owns a DID.
    /// @param owner Address to check.
    /// @return True if the address owns a DID.
    function hasDID(address owner) external view returns (bool) {
        return _hasDID[owner];
    }

    /// @notice Deactivates a DID NFT.
    /// @param tokenId ID of the DID NFT.
    function deactivateDID(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotDIDOwner();
        _profiles[tokenId].isActive = false;
        emit DIDDeactivated(tokenId, msg.sender);
    }

    /// @notice Sets the base URI for DID metadata.
    /// @param newBaseURI New base URI.
    function setBaseURI(string memory newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
    }

    /// @notice Blacklists a user, preventing DID creation.
    /// @param user Address to blacklist.
    /// @param reason Reason for blacklisting.
    function blacklistUser(address user, string memory reason) external onlyOwner {
        isBlacklisted[user] = true;
        emit UserBlacklisted(user, reason);
    }

    /// @notice Whitelists a user, allowing DID creation.
    /// @param user Address to whitelist.
    function whitelistUser(address user) external onlyOwner {
        isBlacklisted[user] = false;
        emit UserWhitelisted(user);
    }

    /// @notice Returns the token URI for a DID NFT.
    /// @param tokenId ID of the DID NFT.
    /// @return URI string.
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        if (!_tokenExists(tokenId)) revert DIDNotExists();
        return string(abi.encodePacked(
            baseURI,
            Strings.toString(tokenId),
            "?name=",
            _profiles[tokenId].name,
            "&avatar=",
            _profiles[tokenId].avatarURI,
            "&cover=",
            _profiles[tokenId].coverPhotoURI
        ));
    }

    /// @notice Handles token transfers, updating DID ownership mappings.
    /// @dev This function is called before any token transfer
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        
        // Call parent _update function
        address result = super._update(to, tokenId, auth);
    
        if (from != address(0) && to != address(0)) {
            // Update hasDID status
            _hasDID[from] = _ownerToDIDs[from].length > 1;
            _hasDID[to] = true;
            
            // Add tokenId to new owner's list
            _ownerToDIDs[to].push(tokenId);
            
            // Remove tokenId from previous owner's list
            uint256[] storage dids = _ownerToDIDs[from];
            for (uint256 i = 0; i < dids.length; i++) {
                if (dids[i] == tokenId) {
                    dids[i] = dids[dids.length - 1];
                    dids.pop();
                    break;
                }
            }
        } else if (from == address(0)) {
            // Minting: add to new owner's list
            _ownerToDIDs[to].push(tokenId);
            _hasDID[to] = true;
        } else if (to == address(0)) {
            // Burning: remove from owner's list
            uint256[] storage dids = _ownerToDIDs[from];
            for (uint256 i = 0; i < dids.length; i++) {
                if (dids[i] == tokenId) {
                    dids[i] = dids[dids.length - 1];
                    dids.pop();
                    break;
                }
            }
            _hasDID[from] = _ownerToDIDs[from].length > 0;
            
            // this Clean up profile data
            delete _profiles[tokenId];
        }
        
        return result;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

