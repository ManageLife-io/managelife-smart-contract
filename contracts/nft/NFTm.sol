// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

interface IAdminControl {
    function isAdmin(address account) external view returns (bool);
    function isLegalAuthority(address account) external view returns (bool);
    function operator() external view returns (address);
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

    // ======== 核心修复点 ========
    constructor(
        address adminControlAddress,
        address initialOwner
    ) ERC721("RealEstateNFT", "RNFT") {
        adminController = IAdminControl(adminControlAddress);
        _transferOwnership(initialOwner);
    }

    // ======== 核心功能 ========
    function mintPropertyNFT(
        address to,
        string memory tokenURI_,
        LegalInfo calldata legalInfo
    ) external nonReentrant returns (uint256) {
        require(
            _approvedMinters[msg.sender] || 
            msg.sender == adminController.operator(),
            "Minter Authorization Required"
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

    // ======== 元数据管理 ========
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
        return string(abi.encodePacked(_tokenURIs[tokenId], "/metadata.json"));
    }

    // ======== 权限管理 ========
    modifier onlyAdmin() {
        require(adminController.isAdmin(msg.sender), "Admin Privilege Required");
        _;
    }

    modifier onlyLegalAuthority() {
        require(
            adminController.isLegalAuthority(msg.sender),
            "Legal Authority Required"
        );
        _;
    }

    function addApprovedMinter(address minter) external onlyAdmin {
        _approvedMinters[minter] = true;
    }

    function revokeMinter(address minter) external onlyAdmin {
        delete _approvedMinters[minter];
    }

    // ======== 系统管理 ========
    function setAdminController(address newController) external onlyOwner {
        adminController = IAdminControl(newController);
        emit ControllershipTransferred(newController);
    }

    // ======== 内部工具 ========
    function _verifyTokenExistence(uint256 tokenId) internal view {
        require(_exists(tokenId), "Token Does Not Exist");
    }

    function _setTokenURI(uint256 tokenId, string memory uri) internal {
        require(bytes(uri).length > 0, "Empty Metadata URI");
        _tokenURIs[tokenId] = uri;
        emit MetadataUpdated(tokenId);
    }

    function _validateLegalInfo(LegalInfo memory info) internal pure returns (bool) {
        return (
            bytes(info.LLCNumber).length >= 5 &&
            bytes(info.jurisdiction).length == 2 &&
            info.registryDate > 1609459200  // 2021-01-01之后
        );
    }

    // ======== 视图函数 ========
    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter.current();
    }

    function isApprovedMinter(address account) public view returns (bool) {
        return _approvedMinters[account];
    }
}

