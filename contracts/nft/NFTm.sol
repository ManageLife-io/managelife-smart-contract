// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

// Updated interface to match AdminControl's role system
interface IAdminControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
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
    address public nftiContract; // Reference to the NFTi contract
    
    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => LegalInfo) public legalRecords;
    mapping(address => bool) private _approvedMinters;
    mapping(uint256 => uint256) public nftiToNftm; // Mapping from NFTi ID to NFTm ID

    event MetadataUpdated(uint256 indexed tokenId);
    event LegalRecordUpdated(uint256 indexed tokenId);
    event ControllershipTransferred(address newController);
    event NFTiContractSet(address indexed nftiContractAddress);
    event NFTmOrphaned(uint256 indexed nftmTokenId, uint256 indexed nftiTokenId);
    event MinterAdded(address indexed minter, address indexed admin);
    event MinterRemoved(address indexed minter, address indexed admin);

    constructor(
        address adminControlAddress,
        address initialOwner,
        address _nftiContract
    ) ERC721("RealEstateNFT", "RNFT") {
        _transferOwnership(initialOwner);
        adminController = IAdminControl(adminControlAddress);
        if (_nftiContract != address(0)) {
            nftiContract = _nftiContract;
            emit NFTiContractSet(_nftiContract);
        }
    }

    // ======== Core Functions ========
    // Added explicit role check in minting function
    function mintPropertyNFT(
        address to,
        string memory tokenURI_,
        LegalInfo calldata legalInfo,
        uint256 nftiTokenId
    ) external nonReentrant returns (uint256) {
        require(adminController.hasRole(keccak256("OPERATOR_ROLE"), msg.sender), 
            "NFTm: caller lacks operator role");
        require(
            _approvedMinters[msg.sender] || 
            msg.sender == adminController.operator(),
            "Minter Authorization Required"
        );
        require(_validateLegalInfo(legalInfo), "Invalid legal data");
        
        // First perform all checks
        bool nftiExists = false;
        if (nftiTokenId > 0 && nftiContract != address(0)) {
            // Try-catch to handle potential revert if token doesn't exist
            try IERC721(nftiContract).ownerOf(nftiTokenId) returns (address) {
                nftiExists = true; // NFTi token exists, proceed with linking
            } catch {
                revert("NFTi token does not exist");
            }
        }

        // Then make state changes (Effects)
        _tokenIdCounter.increment();
        uint256 newTokenId = _tokenIdCounter.current();

        _safeMint(to, newTokenId);
        _setTokenURI(newTokenId, tokenURI_);
        legalRecords[newTokenId] = legalInfo;
        
        // Link NFTm to NFTi if provided and verified
        if (nftiTokenId > 0 && nftiExists) {
            nftiToNftm[nftiTokenId] = newTokenId;
        }

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

    // ======== Metadata Management ========
    function tokenURI(uint256 tokenId) 
        public 
        view 
        virtual 
        override 
        returns (string memory) 
    {
        require(_ownsToken(tokenId), "ERC721Metadata: URI query for nonexistent token");
        return string(abi.encodePacked(_tokenURIs[tokenId], "/metadata.json"));
    }

    // ======== Permission Management ========
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
        require(!_approvedMinters[minter], "Minter already approved");
        _approvedMinters[minter] = true;
        emit MinterAdded(minter, msg.sender);
    }

    function revokeMinter(address minter) external onlyAdmin {
        require(_approvedMinters[minter], "Minter not approved");
        delete _approvedMinters[minter];
        emit MinterRemoved(minter, msg.sender);
    }

    // ======== System Management ========
    function setAdminController(address newController) external onlyOwner {
        adminController = IAdminControl(newController);
        emit ControllershipTransferred(newController);
    }
    
    function setNFTiContract(address _nftiContract) external onlyOwner {
        require(_nftiContract != address(0), "Invalid NFTi contract address");
        nftiContract = _nftiContract;
        emit NFTiContractSet(_nftiContract);
    }
    
    // Function to handle orphaned NFTm tokens when NFTi is burned
    function handleNFTiBurn(uint256 nftiTokenId) external {
        // Only NFTi contract or admin can call this
        require(
            msg.sender == nftiContract || 
            adminController.isAdmin(msg.sender),
            "Unauthorized: only NFTi contract or admin"
        );
        
        uint256 nftmTokenId = nftiToNftm[nftiTokenId];
        if (nftmTokenId > 0 && _ownsToken(nftmTokenId)) {
            // Mark the NFTm as orphaned by removing the link
            delete nftiToNftm[nftiTokenId];
            emit NFTmOrphaned(nftmTokenId, nftiTokenId);
        }
    }

    // ======== Internal Utilities ========
    function _verifyTokenExistence(uint256 tokenId) internal view {
        require(_ownsToken(tokenId), "Token Does Not Exist");
    }

    function _setTokenURI(uint256 tokenId, string memory uri) internal {
        require(bytes(uri).length > 0, "Empty Metadata URI");
        _tokenURIs[tokenId] = uri;
        emit MetadataUpdated(tokenId);
    }

    function _validateLegalInfo(LegalInfo memory info) internal pure returns (bool) {
        return (bytes(info.LLCNumber).length >= 5 && 
                bytes(info.jurisdiction).length == 2 &&
                info.registryDate > 1609459200); // After 2021-01-01
    }

    // ======== View Functions ========
    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter.current();
    }

    function isApprovedMinter(address account) external view returns (bool) {
        return _approvedMinters[account];
    }
    
    function getNFTiForToken(uint256 nftmTokenId) external view returns (uint256) {
        // Find the NFTi token ID associated with this NFTm token
        for (uint256 i = 1; i <= _tokenIdCounter.current(); i++) {
            if (nftiToNftm[i] == nftmTokenId) {
                return i;
            }
        }
        return 0; // Return 0 if no associated NFTi token found
    }
    
    function isOrphaned(uint256 nftmTokenId) external view returns (bool) {
        // Check if token exists
        if (!_ownsToken(nftmTokenId)) {
            return false; // Non-existent tokens are not considered orphaned
        }
        
        // Check if there's an associated NFTi token
        uint256 nftiTokenId = getNFTiForToken(nftmTokenId);
        
        // If no NFTi token is associated, it's orphaned
        if (nftiTokenId == 0) {
            return true;
        }
        
        // Check if NFTi contract is set
        if (nftiContract == address(0)) {
            return true; // If no NFTi contract is set, consider it orphaned
        }
        
        // Check if the NFTi token still exists (external call last)
        try IERC721(nftiContract).ownerOf(nftiTokenId) returns (address) {
            return false; // NFTi token exists, so not orphaned
        } catch {
            return true; // NFTi token doesn't exist, so orphaned
        }
    }

    // ===== Core Fix Point =====
    function _ownsToken(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
}
