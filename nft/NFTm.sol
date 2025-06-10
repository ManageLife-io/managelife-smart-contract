// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @title NFTm - Real Estate NFT Token Implementation
/// @notice Implements ERC721 token for real estate properties with metadata and access control
/// @dev Inherits from ERC721URIStorage for metadata, AccessControl for roles, and ReentrancyGuard for security
contract NFTm is ERC721URIStorage, ERC721Enumerable, AccessControl, ReentrancyGuard, Pausable {
    using Counters for Counters.Counter;
    using Strings for uint256;

    // ========== Role Definitions ==========
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ========== State Variables ==========
    Counters.Counter private _tokenIds;
    
    // Property metadata
    struct PropertyMetadata {
        string propertyType;     // residential, commercial, industrial, etc.
        string location;         // physical location of the property
        uint256 squareMeters;   // size in square meters
        uint256 yearBuilt;      // year the property was built
        bool isVerified;        // verification status
        address verifier;       // address that verified the property
        uint256 verificationDate; // timestamp of verification
    }
    
    // Mapping from token ID to property metadata
    mapping(uint256 => PropertyMetadata) private _propertyMetadata;
    
    // Mapping for property verification status
    mapping(uint256 => bool) public isPropertyVerified;
    
    // Base URI for token metadata
    string private _baseTokenURI;

    // ========== Events ==========
    event PropertyMinted(
        uint256 indexed tokenId,
        address indexed owner,
        string propertyType,
        string location,
        uint256 squareMeters,
        uint256 yearBuilt
    );
    
    event PropertyVerified(
        uint256 indexed tokenId,
        address indexed verifier,
        uint256 verificationDate
    );
    
    event BaseURIUpdated(string newBaseURI, address indexed admin);
    event MetadataUpdated(uint256 indexed tokenId, address indexed updater);

    // ========== Constructor ==========
    constructor(
        string memory name,
        string memory symbol,
        string memory baseTokenURI,
        address admin
    ) ERC721(name, symbol) {
        require(bytes(baseTokenURI).length > 0, "Base URI cannot be empty");
        require(admin != address(0), "Invalid admin address");

        _baseTokenURI = baseTokenURI;
        
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(MINTER_ROLE, admin);
        _setupRole(ADMIN_ROLE, admin);
        _setupRole(PAUSER_ROLE, admin);
    }

    // ========== Modifiers ==========
    modifier onlyVerifiedProperty(uint256 tokenId) {
        require(isPropertyVerified[tokenId], "Property not verified");
        _;
    }

    modifier validTokenId(uint256 tokenId) {
        require(_exists(tokenId), "Token does not exist");
        _;
    }

    // ========== External Functions ==========
    function mint(
        address to,
        string memory propertyType,
        string memory location,
        uint256 squareMeters,
        uint256 yearBuilt,
        string memory tokenURI
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant returns (uint256) {
        require(to != address(0), "Invalid recipient address");
        require(bytes(propertyType).length > 0, "Property type cannot be empty");
        require(bytes(location).length > 0, "Location cannot be empty");
        require(squareMeters > 0, "Invalid square meters");
        require(yearBuilt > 0 && yearBuilt <= block.timestamp / 365 days + 1970, "Invalid year built");

        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();

        _safeMint(to, newTokenId);
        _setTokenURI(newTokenId, tokenURI);

        _propertyMetadata[newTokenId] = PropertyMetadata({
            propertyType: propertyType,
            location: location,
            squareMeters: squareMeters,
            yearBuilt: yearBuilt,
            isVerified: false,
            verifier: address(0),
            verificationDate: 0
        });

        emit PropertyMinted(
            newTokenId,
            to,
            propertyType,
            location,
            squareMeters,
            yearBuilt
        );

        return newTokenId;
    }

    function verifyProperty(uint256 tokenId)
        external
        onlyRole(ADMIN_ROLE)
        validTokenId(tokenId)
        whenNotPaused
        nonReentrant
    {
        require(!isPropertyVerified[tokenId], "Property already verified");
        
        PropertyMetadata storage metadata = _propertyMetadata[tokenId];
        metadata.isVerified = true;
        metadata.verifier = msg.sender;
        metadata.verificationDate = block.timestamp;
        
        isPropertyVerified[tokenId] = true;

        emit PropertyVerified(tokenId, msg.sender, block.timestamp);
    }

    function updateMetadata(
        uint256 tokenId,
        string memory propertyType,
        string memory location,
        uint256 squareMeters,
        uint256 yearBuilt
    )
        external
        onlyRole(ADMIN_ROLE)
        validTokenId(tokenId)
        whenNotPaused
        nonReentrant
    {
        require(bytes(propertyType).length > 0, "Property type cannot be empty");
        require(bytes(location).length > 0, "Location cannot be empty");
        require(squareMeters > 0, "Invalid square meters");
        require(yearBuilt > 0 && yearBuilt <= block.timestamp / 365 days + 1970, "Invalid year built");

        PropertyMetadata storage metadata = _propertyMetadata[tokenId];
        metadata.propertyType = propertyType;
        metadata.location = location;
        metadata.squareMeters = squareMeters;
        metadata.yearBuilt = yearBuilt;

        emit MetadataUpdated(tokenId, msg.sender);
    }

    function setBaseURI(string memory newBaseURI)
        external
        onlyRole(ADMIN_ROLE)
        whenNotPaused
    {
        require(bytes(newBaseURI).length > 0, "Base URI cannot be empty");
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI, msg.sender);
    }

    // ========== View Functions ==========
    function getPropertyMetadata(uint256 tokenId)
        external
        view
        validTokenId(tokenId)
        returns (
            string memory propertyType,
            string memory location,
            uint256 squareMeters,
            uint256 yearBuilt,
            bool isVerified,
            address verifier,
            uint256 verificationDate
        )
    {
        PropertyMetadata memory metadata = _propertyMetadata[tokenId];
        return (
            metadata.propertyType,
            metadata.location,
            metadata.squareMeters,
            metadata.yearBuilt,
            metadata.isVerified,
            metadata.verifier,
            metadata.verificationDate
        );
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        validTokenId(tokenId)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // ========== Emergency Controls ==========
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ========== Required Overrides ==========
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) whenNotPaused {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }
} 