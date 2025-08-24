// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IAdminControl} from "../interfaces/IAdminControl.sol";

/// @title ManageLife Property NFT
/// @notice ERC-721 for ManageLife property tokens, minted and managed via an external controller.
/// @dev
/// - Minting and deed state updates are restricted to `propertyControllerContract`.
/// - Administrative wiring (admin/controller addresses, base URI) is restricted to `DEFAULT_ADMIN_ROLE` via `IAdminControl`.
/// - LLC/legal property information MUST live in the off-chain NFT metadata (e.g., tokenURI JSON), not on-chain:
///   - to minimize gas/storage costs
///   - and because such information is authored by the platform, not by end-users.
contract ManageLifePropertyNFT is ERC721 {
    using Strings for uint256;
    /// @dev Sequential token ID counter. Incremented on each mint.
    uint256 private _tokenIdCounter;

    /// @dev Normalized base URI (always ends with a single '/').
    string private _baseTokenURI;

    /// @notice The system’s admin control contract.
    IAdminControl public adminController;

    /// @notice Contract allowed to mint and update deed state.
    address public propertyControllerContract;

    /// @notice Whether the deed for a given tokenId is held at ManageLife.
    /// @dev Updated only by `propertyControllerContract`.
    mapping(uint256 => bool) public deedHeldAtManageLife;

    /// @notice Emitted when the base token URI is updated.
    /// @param baseTokenURI The new base URI
    event BaseTokenURISet(string indexed baseTokenURI);

    /// @notice Emitted when the admin control contract is updated.
    /// @param oldAdminContract Previous admin controller address
    /// @param newAdminContract New admin controller address
    event AdminContractUpdated(address oldAdminContract, address newAdminContract);

    /// @notice Emitted when the property controller contract is updated.
    /// @param oldController Previous controller address
    /// @param newController New controller address
    event ControllerContractUpdated(address oldController, address newController);

    /// @notice Emitted when the deed-held flag is updated for a token.
    /// @param tokenId Token ID whose deed-held flag was updated.
    /// @param deedHeldAtManageLife New deed-held flag value.
    event DeedHeldAtManageLifeUpdated(uint256 indexed tokenId, bool deedHeldAtManageLife);

    /// @dev Revert when a zero address is provided where non-zero is required.
    error ZeroAddress();

    /// @dev Revert when caller lacks `DEFAULT_ADMIN_ROLE`.
    error NotAdmin();

    /// @dev Revert when caller is not the configured `propertyControllerContract`.
    error NotController();

    /// @dev Revert when an empty base URI is provided.
    error EmptyMetadataURI();

    /// @dev Revert when a function is called by an address that does not have the PROTOCOL_PARAM_MANAGER_ROLE.
    error OnlyProtocolParamManagerCanCall();

    /// @notice Restricts caller to `DEFAULT_ADMIN_ROLE` from `adminController`.
    modifier onlyAdmin() {
        if (!adminController.hasRole(adminController.DEFAULT_ADMIN_ROLE(), msg.sender)) {
            revert NotAdmin();
        }
        _;
    }

    /**
     * @dev Throws if called by any account that does not have the PROTOCOL_PARAM_MANAGER_ROLE.
     */
    modifier onlyProtocolParamManager() {
        if (!adminController.hasRole(adminController.PROTOCOL_PARAM_MANAGER_ROLE(), msg.sender)) {
            revert OnlyProtocolParamManagerCanCall();
        }
        _;
    }

    /// @notice Restricts caller to the configured `propertyControllerContract`.
    modifier onlyController() {
        if (propertyControllerContract != msg.sender) {
            revert NotController();
        }
        _;
    }

    /// @notice Modifier that checks if a function is paused in the AdminControl contract.
    /// @param functionId The ID of the function to check.
    modifier whenFunctionActive(bytes32 functionId) {
        adminController.checkPaused(functionId);
        _;
    }

    /// @notice Deploys the collection with admin/controller wiring and an initial base URI.
    /// @dev `_baseUri` is normalized to a single trailing '/'.
    /// @param name ERC-721 name.
    /// @param symbol ERC-721 symbol.
    /// @param adminControlAddress Protocol's `IAdminControl` contract.
    /// @param _baseUri Base URI for token metadata (directory-like, with or without trailing slash).
    /// @param _controllerContract Address of the property controller authorized to mint and update deed state.
    constructor(
        string memory name,
        string memory symbol,
        IAdminControl adminControlAddress,
        string memory _baseUri,
        address _controllerContract
    ) ERC721(name, symbol) {
        if (bytes(_baseUri).length == 0) revert EmptyMetadataURI();
        if (address(adminControlAddress) == address(0)) revert ZeroAddress();
        if (_controllerContract == address(0)) revert ZeroAddress();
        adminController = adminControlAddress;
        propertyControllerContract = _controllerContract;
        _baseTokenURI = _normalizeBaseUri(_baseUri);
    }

    /// @notice Mints a new token to `to` and sets its deed-held flag.
    /// @dev Callable only by `propertyControllerContract`.
    /// @param to Recipient of the newly minted token.
    /// @param _deedHeldAtManageLife Whether the deed is held at ManageLife for the new property token.
    /// @return newTokenId The ID of the minted token.
    function mintPropertyNFT(address to, bool _deedHeldAtManageLife)
        external
        onlyController
        returns (uint256 newTokenId)
    {
        newTokenId = ++_tokenIdCounter;
        deedHeldAtManageLife[newTokenId] = _deedHeldAtManageLife;
        _safeMint(to, newTokenId);
    }

    /// @notice Updates the deed-held flag for a token.
    /// @dev Callable only by `propertyControllerContract`. Reverts if token does not exist.
    /// @param tokenId Token ID whose deed-held flag will be updated.
    /// @param _deedHeldAtManageLife New deed-held flag value.
    function setDeedHeldAtManageLife(uint256 tokenId, bool _deedHeldAtManageLife) external onlyController {
        _requireOwned(tokenId);
        deedHeldAtManageLife[tokenId] = _deedHeldAtManageLife;
        emit DeedHeldAtManageLifeUpdated(tokenId, _deedHeldAtManageLife);
    }

    /// @notice Returns the token metadata URI for `tokenId` as base + tokenId + ".json".
    /// @dev Reverts if token does not exist.
    /// @param tokenId Token ID for the metadata lookup.
    /// @return uri Fully qualified token metadata URI.
    function tokenURI(uint256 tokenId) public view override returns (string memory uri) {
        _requireOwned(tokenId);
        uri = string(abi.encodePacked(_baseTokenURI, tokenId.toString(), ".json"));
    }

    /// @notice Returns the current base token URI (normalized to a single trailing slash).
    function baseTokenURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    /// @notice Sets the property controller contract address.
    /// @dev Only `DEFAULT_ADMIN_ROLE`. Reverts on zero address.
    /// @param newPropertyController The new controller address.
    function setPropertyControllerContract(address newPropertyController) external onlyAdmin whenFunctionActive(adminController.PROTOCOL_WIRING_CONFIGURATION()) {
        if (newPropertyController == address(0)) revert ZeroAddress();
        address oldPropertyController = propertyControllerContract;
        propertyControllerContract = newPropertyController;
        emit ControllerContractUpdated(oldPropertyController, newPropertyController);
    }

    /// @notice Sets the admin controller contract address.
    /// @dev Only `DEFAULT_ADMIN_ROLE`. Reverts on zero address.
    /// @param newAdminController The new admin controller address.
    function setAdminController(address newAdminController) external onlyAdmin whenFunctionActive(adminController.PROTOCOL_WIRING_CONFIGURATION()) {
        if (newAdminController == address(0)) revert ZeroAddress();
        address oldAdminController = address(adminController);
        adminController = IAdminControl(newAdminController);
        emit AdminContractUpdated(oldAdminController, newAdminController);
    }

    /// @notice Updates the base token URI. Accepts inputs with or without trailing slashes.
    /// @dev Only `DEFAULT_ADMIN_ROLE`. Normalized to exactly one trailing '/' before storage.
    /// @param _baseUri New base URI string.
    function setBaseTokenURI(string memory _baseUri) external onlyProtocolParamManager whenFunctionActive(adminController.PROTOCOL_PARAM_CONFIGURATION()) {
        if (bytes(_baseUri).length == 0) revert EmptyMetadataURI();
        _baseTokenURI = _normalizeBaseUri(_baseUri);
        emit BaseTokenURISet(_baseTokenURI);
    }

    /// @dev Normalizes an input URI to exactly one trailing '/'.
    /// @param s Input URI (may have zero or multiple trailing slashes).
    /// @return normalized Normalized URI with exactly one trailing '/'.
    function _normalizeBaseUri(string memory s) internal pure returns (string memory normalized) {
        bytes memory b = bytes(s);
        if (b.length == 0) return s;

        uint256 end = b.length;
        while (end > 0 && b[end - 1] == bytes1("/")) {
            unchecked {
                end--;
            }
        }

        if (end == 0) return "/";

        bytes memory trimmed = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            trimmed[i] = b[i];
        }
        normalized = string(abi.encodePacked(trimmed, "/"));
    }

    /// @notice Total number of tokens minted so far.
    /// @dev This counts minted tokens and does not decrement on burn (if ever added).
    /// @return supply The current mint counter.
    function totalSupply() public view returns (uint256 supply) {
        supply = _tokenIdCounter;
    }
}
