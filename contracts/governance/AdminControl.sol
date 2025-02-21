// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

interface IAdminControl {
    function isAdmin(address) external view returns (bool);
    function isLegalAuthority(address) external view returns (bool);
    function isMinter(address) external view returns (bool);
}

contract NFTm is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;
    using Counters for Counters.Counter;

    struct LegalInfo {
        string LLCNumber;
        string jurisdiction;
        uint256 registryDate;
    }

    Counters.Counter private _tokenIdCounter;
    IAdminControl public adminController;
    
    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => LegalInfo) public legalRecords;
    mapping(address => bool) private _approvedMinters;

    event MetadataUpdated(uint256 indexed tokenId);
    event LegalRecordUpdated(uint256 indexed tokenId);
    event ControllershipTransferred(address newController);

    constructor(
        address adminControlAddress,
        address initialOwner
    ) ERC721("RealEstateNFT", "RNFT") Ownable(initialOwner) {
        adminController = IAdminControl(adminControlAddress);
    }

    function _verifyTokenExistence(uint256 tokenId) internal view {
        require(_ownerOf(tokenId) != address(0), "ERC721: Invalid token ID");
    }

    function mintPropertyNFT(
        address to,
        string memory tokenURI_,
        LegalInfo calldata legalInfo
    ) external nonReentrant returns (uint256) {
        require(
            _approvedMinters[msg.sender] || adminController.isMinter(msg.sender),
            "Minter authorization required"
        );
        require(_validateLegalInfo(legalInfo), "Invalid legal data");

        _tokenIdCounter.increment();
        uint256 newTokenId = _tokenIdCounter.current();

        _safeMint(to, newTokenId);
        _setTokenURI(newTokenId, tokenURI_);
        legalRecords[newTokenId] = legalInfo;

        return newTokenId;
    }

    function updateLegalRecord(
        uint256 tokenId,
        LegalInfo calldata newInfo
    ) external onlyLegalAuthority {
        _verifyTokenExistence(tokenId);
        legalRecords[tokenId] = newInfo;
        emit LegalRecordUpdated(tokenId);
    }

    function _setTokenURI(uint256 tokenId, string memory uri) internal {
        require(bytes(uri).length > 0, "Empty URI");
        _tokenURIs[tokenId] = uri;
        emit MetadataUpdated(tokenId);
    }

    function tokenURI(uint256 tokenId) 
        public 
        view 
        virtual 
        override 
        returns (string memory) 
    {
        _verifyTokenExistence(tokenId);
        return string(abi.encodePacked(_tokenURIs[tokenId], "/metadata.json"));
    }

    modifier onlyAdmin() {
        require(adminController.isAdmin(msg.sender), "Admin required");
        _;
    }

    modifier onlyLegalAuthority() {
        require(adminController.isLegalAuthority(msg.sender), "Legal authority required");
        _;
    }

    function addApprovedMinter(address minter) external onlyAdmin {
        _approvedMinters[minter] = true;
    }

    function revokeMinter(address minter) external onlyAdmin {
        delete _approvedMinters[minter];
    }

    function setAdminController(address newController) external onlyOwner {
        adminController = IAdminControl(newController);
        emit ControllershipTransferred(newController);
    }

    function _validateLegalInfo(LegalInfo memory info) internal pure returns (bool) {
        return (bytes(info.LLCNumber).length >= 5 && 
                bytes(info.jurisdiction).length == 2 &&
                info.registryDate > 1609459200);
    }

    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter.current();
    }

    function isMinterApproved(address account) public view returns (bool) {
        return _approvedMinters[account];
    }
}
