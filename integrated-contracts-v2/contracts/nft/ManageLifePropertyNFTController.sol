// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IAdminControl} from "../interfaces/IAdminControl.sol";
import {IManageLifePropertyNFT} from "../interfaces/IManageLifePropertyNFT.sol";

/// @title ManageLifePropertyNFTController
/// @author Jose Herrera
/// @notice This contract is responsible for controlling the minting process of ManageLifePropertyNFTs.
/// It acts as a layer between the admin/managers and the NFT contract itself, enforcing specific roles for minting.
contract ManageLifePropertyNFTController{
    // ============ Immutable/State ============
    /// @notice The address of the AdminControl contract.
    IAdminControl public adminController;
    /// @notice The address of the ManageLifePropertyNFT contract that this controller manages.
    IManageLifePropertyNFT public manageLifePropertiesNftContract;
    /// @notice The maximum number of NFTs that can be minted in a single batch transaction.
    uint256 public immutable MAX_BATCH_SIZE = 25;

    // ============ Events ============
    /// @notice Emitted when a new property NFT is minted.
    /// @param to The address receiving the new NFT.
    /// @param tokenId The ID of the newly minted token.
    /// @param caller The address that initiated the minting.
    event PropertyMinted(address indexed to, uint256 tokenId, address indexed caller);
    /// @notice Emitted when the ManageLifePropertyNFT contract address is updated.
    /// @param newPropertyNFTContract The address of the new NFT contract.
    event ManageLifePropertyNFTContractUpdated(address oldPropertyNFTContract, address newPropertyNFTContract);
    /// @notice Emitted when the AdminControl contract address is updated.
    /// @param newAdminController The address of the new admin controller.
    event AdminControllerUpdated(address oldAdminController, address newAdminController);

    // ============ Errors ============
    /// @notice Thrown when a function is called with a zero address parameter where it is not allowed.
    error ZeroAddress();
    /// @notice Thrown when a function is called by an address that does not have the NFT_PROPERTY_MANAGER_ROLE.
    error NotNftPropertyManager();
    /// @notice Thrown when a function is called by an address that is not a default admin.
    error NotAdmin();
    /// @notice Thrown when a batch minting operation exceeds the maximum allowed batch size.
    /// @param batchSize The requested batch size.
    /// @param maxBatchSize The maximum allowed batch size.
    error InvalidBatchSize(uint256 batchSize, uint256 maxBatchSize);
    /// @notice Thrown when the input arrays for a batch operation do not have the same length.
    error InvalidBatchDataInputs();
    
    /// @notice Thrown when trying to set a new NFT contract that points to a different controller, when it should be this contract.
    /// @param controllerOnNftContract The controller address on the new NFT contract.
    error newNFTContractHasDifferentController(address controllerOnNftContract);
    /// @notice Thrown when trying to set a new NFT contract that points to a different admin controller.
    /// @param adminControllerOnNftContract The admin controller address on the new NFT contract.
    /// @param currentAdminController The address of the current admin controller in this contract.
    error newNFTContractHasDifferentAdminController(address adminControllerOnNftContract, address currentAdminController);

    // ============ Constructor ============
    /// @notice Initializes the controller with the addresses of the AdminControl and ManageLifePropertyNFT contracts.
    /// @param _adminControlAddress The address of the AdminControl contract.
    /// @param _manageLifePropertiesNftContract The address of the ManageLifePropertyNFT contract.
    constructor(IAdminControl _adminControlAddress, IManageLifePropertyNFT _manageLifePropertiesNftContract) {
        if (address(_adminControlAddress) == address(0)) {
            revert ZeroAddress();
        }
        if (address(_manageLifePropertiesNftContract) == address(0)) {
            revert ZeroAddress();
        }
        adminController = _adminControlAddress;

        _checkNftContractConnections(_manageLifePropertiesNftContract);

        manageLifePropertiesNftContract = _manageLifePropertiesNftContract;
    }

    // ============ Modifiers ============
    /// @notice Modifier to restrict function access to default admins only.
    modifier onlyAdmin() {
        if (!adminController.hasRole(adminController.DEFAULT_ADMIN_ROLE(), msg.sender)) {
            revert NotAdmin();
        }
        _;
    }
    
    /// @notice Modifier to restrict function access to NFT Property Managers only.
    modifier onlyNftPropertyManager() {
        if (!adminController.hasRole(adminController.NFT_PROPERTY_MANAGER_ROLE(), msg.sender)) {
            revert NotNftPropertyManager();
        }
        _;
    }

    // ============ Admin Functions ============
    /// @notice Updates the AdminControl contract address.
    /// @dev This function can only be called by a default admin.
    /// @param newController The new AdminControl contract instance.
    function setAdminController(IAdminControl newController) external onlyAdmin {
        if (address(newController) == address(0)) {
            revert ZeroAddress();
        }
        address oldAdminController = address(adminController);
        adminController = IAdminControl(newController);
        emit AdminControllerUpdated(oldAdminController,address(newController));
    }

    /// @notice Sets the `deedHeldAtManageLife` status for a specific property NFT.
    /// @dev This can only be called by an address with the NFT_PROPERTY_MANAGER_ROLE.
    /// @param tokenId The ID of the token to update.
    /// @param deedHeldAtManageLife The new boolean status.
    function setDeedHeldAtManageLife(uint256 tokenId, bool deedHeldAtManageLife) external onlyNftPropertyManager {
        manageLifePropertiesNftContract.setDeedHeldAtManageLife(tokenId, deedHeldAtManageLife);
    }

    /// @notice Updates the ManageLifePropertyNFT contract address.
    /// @dev This function can only be called by a default admin.
    /// The new NFT contract must have this contract as its controller and the same admin controller.
    /// @param newPropertyNFTContract The new ManageLifePropertyNFT contract instance.
    function setManageLifePropertyNFTContract(IManageLifePropertyNFT newPropertyNFTContract) external onlyAdmin {
        if (address(newPropertyNFTContract) == address(0)) {
            revert ZeroAddress();
        }
        _checkNftContractConnections(newPropertyNFTContract);

        address oldPropertyNFTContract = address(manageLifePropertiesNftContract);
        manageLifePropertiesNftContract = newPropertyNFTContract;
        emit ManageLifePropertyNFTContractUpdated(oldPropertyNFTContract, address(newPropertyNFTContract));
    }

    // ============ Minting ============
    /// @notice Mints a new property NFT and assigns it to a specified address.
    /// @dev Can only be called by an address with the NFT_PROPERTY_MANAGER_ROLE.
    /// @param to The address to mint the new NFT to.
    /// @param deedHeldAtManageLife A boolean indicating if the deed is held by ManageLife.
    /// @return tokenId The ID of the newly minted token.
    function mint(address to, bool deedHeldAtManageLife) external onlyNftPropertyManager returns (uint256) {
        uint256 tokenId = manageLifePropertiesNftContract.mintPropertyNFT(to, deedHeldAtManageLife);
        emit PropertyMinted(to, tokenId, msg.sender);
        return tokenId;
    }

    /// @notice Mints a batch of new property NFTs to specified addresses.
    /// @dev Can only be called by an address with the NFT_PROPERTY_MANAGER_ROLE.
    /// The length of `recipients` and `deedHeldAtManageLife` arrays must be equal.
    /// Batch size is limited by `MAX_BATCH_SIZE`.
    /// @param recipients An array of addresses to mint the new NFTs to.
    /// @param deedHeldAtManageLife An array of booleans indicating if the deeds are held by ManageLife.
    /// @return tokenIds An array of the newly minted token IDs.
    function mintBatch(address[] calldata recipients, bool[] calldata deedHeldAtManageLife) external onlyNftPropertyManager returns (uint256[] memory) {
 
        if (recipients.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(recipients.length, MAX_BATCH_SIZE);
        }
        if(recipients.length != deedHeldAtManageLife.length) {
            revert InvalidBatchDataInputs();
        }
        uint256 length = recipients.length;
        uint256[] memory tokenIds = new uint256[](length);
        for (uint256 i = 0; i < length; ) {
            tokenIds[i] = manageLifePropertiesNftContract.mintPropertyNFT(recipients[i], deedHeldAtManageLife[i]);
            emit PropertyMinted(recipients[i], tokenIds[i], msg.sender);
            unchecked { ++i; }
        }
        return tokenIds;
    }


    /// @dev Checks that the new NFT contract is correctly wired to this controller and the correct admin controller.
    /// Reverts if the NFT contract's controller or admin controller do not match expectations.
    /// @param newPropertyNFTContract The new ManageLifePropertyNFT contract to check.
    function _checkNftContractConnections(IManageLifePropertyNFT newPropertyNFTContract) internal view {
        // Ensure the NFT contract's controller is this contract.
        if (newPropertyNFTContract.propertyControllerContract() != address(this)) {
            revert newNFTContractHasDifferentController(newPropertyNFTContract.propertyControllerContract());
        }
        // Ensure the NFT contract's admin controller matches this controller's admin controller.
        address adminControllerOnNftContract = address(newPropertyNFTContract.adminController());
        if (adminControllerOnNftContract != address(adminController)) {
            revert newNFTContractHasDifferentAdminController(adminControllerOnNftContract, address(adminController));
        }
    }

}
