// test/ManageLifePropertyNFT.t.sol
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ManageLifePropertyNFT} from "../contracts/nft/ManageLifePropertyNFT.sol";
import {IAdminControl} from "../contracts/interfaces/IAdminControl.sol";

contract MockAdminControl is IAdminControl {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    bytes32 public constant DEFAULT_ADMIN_ROLE =
        keccak256("DEFAULT_ADMIN_ROLE");
    bytes32 public constant NFT_PROPERTY_MANAGER_ROLE =
        keccak256("NFT_PROPERTY_MANAGER_ROLE");

    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external {
        _roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external {
        _roles[role][account] = false;
    }
}

contract MockPropertyController {
    ManageLifePropertyNFT public nftContract;

    constructor(ManageLifePropertyNFT _nftContract) {
        nftContract = _nftContract;
    }

    function mintPropertyNFT(
        address to,
        bool isDeedHeldAtManageLife
    ) external returns (uint256) {
        return nftContract.mintPropertyNFT(to, isDeedHeldAtManageLife);
    }

    function setDeedHeldAtManageLife(
        uint256 tokenId,
        bool isDeedHeldAtManageLife
    ) external {
        nftContract.setDeedHeldAtManageLife(tokenId, isDeedHeldAtManageLife);
    }
}

contract ManageLifePropertyNFTTest is Test {
    ManageLifePropertyNFT public nftContract;
    MockAdminControl public adminControl;
    MockPropertyController public controller;

    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);

    // Events
    event BaseTokenURISet(string indexed baseTokenURI);
    event AdminContractUpdated(
        address oldAdminContract,
        address newAdminContract
    );
    event ControllerContractUpdated(
        address oldController,
        address newController
    );
    event DeedHeldAtManageLifeUpdated(
        uint256 indexed tokenId,
        bool deedHeldAtManageLife
    );

    function setUp() public {
        adminControl = new MockAdminControl();

        adminControl.grantRole(adminControl.DEFAULT_ADMIN_ROLE(), admin);

        nftContract = new ManageLifePropertyNFT(
            "ManageLife Property",
            "MLP",
            adminControl,
            "https://api.managelife.com/metadata/",
            address(0)
        );

        // Deploy controller and set it in the NFT contract
        controller = new MockPropertyController(nftContract);

        // Set the controller in the NFT contract
        vm.prank(admin);
        nftContract.setPropertyControllerContract(address(controller));

        // Set up test accounts
        vm.label(admin, "Admin");
        vm.label(user1, "User1");
        vm.label(user2, "User2");
    }

    // ============================================================================
    // CONSTRUCTOR TESTS
    // ============================================================================

    function test_Constructor_Success() public {
        // Test successful deployment
        assertEq(nftContract.name(), "ManageLife Property");
        assertEq(nftContract.symbol(), "MLP");
        assertEq(address(nftContract.adminController()), address(adminControl));
        assertEq(
            nftContract.baseTokenURI(),
            "https://api.managelife.com/metadata/"
        );
    }

    function test_Constructor_RevertOnZeroAdmin() public {
        vm.expectRevert(ManageLifePropertyNFT.ZeroAddress.selector);
        new ManageLifePropertyNFT(
            "Test",
            "TEST",
            IAdminControl(address(0)),
            "https://test.com/",
            address(controller)
        );
    }

    function test_Constructor_RevertOnZeroController() public {
        vm.expectRevert(ManageLifePropertyNFT.ZeroAddress.selector);
        new ManageLifePropertyNFT(
            "Test",
            "TEST",
            adminControl,
            "https://test.com/",
            address(0)
        );
    }

    function test_Constructor_RevertOnEmptyURI() public {
        vm.expectRevert(ManageLifePropertyNFT.EmptyMetadataURI.selector);
        new ManageLifePropertyNFT(
            "Test",
            "TEST",
            adminControl,
            "",
            address(controller)
        );
    }

    // ============================================================================
    // MINTING TESTS
    // ============================================================================

    function test_MintPropertyNFT_Success() public {
        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(user1, true);

        assertEq(tokenId, 1);
        assertEq(nftContract.ownerOf(tokenId), user1);
        assertTrue(nftContract.deedHeldAtManageLife(tokenId));
        assertEq(nftContract.totalSupply(), 1);
    }

    function test_MintPropertyNFT_OnlyController() public {
        vm.prank(user1);
        vm.expectRevert(ManageLifePropertyNFT.NotController.selector);
        nftContract.mintPropertyNFT(user2, false);
    }

    function test_MintPropertyNFT_ToZeroAddress() public {
        vm.prank(address(controller));
        vm.expectRevert(); // ERC721: mint to the zero address
        nftContract.mintPropertyNFT(address(0), true);
    }

    function test_MintPropertyNFT_ToContractAddress() public {
        address contractAddress = address(0x123);
        vm.etch(contractAddress, hex"1234"); // Make it a contract

        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(contractAddress, false);
        assertEq(nftContract.ownerOf(tokenId), contractAddress);
    }

    // ============================================================================
    // DEED MANAGEMENT TESTS
    // ============================================================================

    function test_SetDeedHeldAtManageLife_Success() public {
        // First mint a token
        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(user1, false);

        // Update deed status
        vm.prank(address(controller));
        vm.expectEmit(true, false, false, true);
        emit DeedHeldAtManageLifeUpdated(tokenId, true);
        nftContract.setDeedHeldAtManageLife(tokenId, true);

        assertTrue(nftContract.deedHeldAtManageLife(tokenId));
    }

    function test_SetDeedHeldAtManageLife_OnlyController() public {
        vm.prank(user1);
        vm.expectRevert(ManageLifePropertyNFT.NotController.selector);
        nftContract.setDeedHeldAtManageLife(1, true);
    }

    //  NEW EDGE CASES
    function test_SetDeedHeldAtManageLife_NonExistentToken() public {
        vm.prank(address(controller));
        vm.expectRevert(); // ERC721: owner query for nonexistent token
        nftContract.setDeedHeldAtManageLife(999, true);
    }

    function test_SetDeedHeldAtManageLife_SameValue() public {
        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(user1, true);

        // Setting to same value should still emit event
        vm.prank(address(controller));
        vm.expectEmit(true, false, false, true);
        emit DeedHeldAtManageLifeUpdated(tokenId, true);
        nftContract.setDeedHeldAtManageLife(tokenId, true);
    }

    // ============================================================================
    // ADMIN TESTS
    // ============================================================================

    function test_SetPropertyControllerContract_Success() public {
        address newController = address(0x999);

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit ControllerContractUpdated(address(controller), newController);
        nftContract.setPropertyControllerContract(newController);

        assertEq(nftContract.propertyControllerContract(), newController);
    }

    function test_SetPropertyControllerContract_OnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert(ManageLifePropertyNFT.NotAdmin.selector);
        nftContract.setPropertyControllerContract(address(0x999));
    }

    function test_SetPropertyControllerContract_RevertOnZero() public {
        vm.prank(admin);
        vm.expectRevert(ManageLifePropertyNFT.ZeroAddress.selector);
        nftContract.setPropertyControllerContract(address(0));
    }

    //  NEW EDGE CASES
    function test_SetPropertyControllerContract_ToSelf() public {
        vm.prank(admin);
        nftContract.setPropertyControllerContract(address(nftContract));
        assertEq(
            nftContract.propertyControllerContract(),
            address(nftContract)
        );
    }

    function test_SetPropertyControllerContract_ToNonContract() public {
        address nonContract = address(0x123);
        vm.prank(admin);
        nftContract.setPropertyControllerContract(nonContract);
        assertEq(nftContract.propertyControllerContract(), nonContract);
    }

    // ============================================================================
    // METADATA TESTS
    // ============================================================================

    function test_TokenURI_Success() public {
        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(user1, true);

        string
            memory expectedURI = "https://api.managelife.com/metadata/1.json";
        assertEq(nftContract.tokenURI(tokenId), expectedURI);
    }

    function test_SetBaseTokenURI_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit BaseTokenURISet("https://new-api.com/metadata/");
        nftContract.setBaseTokenURI("https://new-api.com/metadata/");

        assertEq(nftContract.baseTokenURI(), "https://new-api.com/metadata/");
    }

    function test_SetBaseTokenURI_NormalizesTrailingSlashes() public {
        vm.prank(admin);
        nftContract.setBaseTokenURI("https://test.com");
        assertEq(nftContract.baseTokenURI(), "https://test.com/");

        vm.prank(admin);
        nftContract.setBaseTokenURI("https://test2.com///");
        assertEq(nftContract.baseTokenURI(), "https://test2.com/");
    }

    //  NEW EDGE CASES
    function test_TokenURI_NonExistentToken() public {
        vm.expectRevert(); // ERC721: owner query for nonexistent token
        nftContract.tokenURI(999);
    }

    function test_SetBaseTokenURI_OnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert(ManageLifePropertyNFT.NotAdmin.selector);
        nftContract.setBaseTokenURI("https://malicious.com/");
    }

    function test_SetBaseTokenURI_EmptyString() public {
        vm.prank(admin);
        vm.expectRevert(ManageLifePropertyNFT.EmptyMetadataURI.selector);
        nftContract.setBaseTokenURI("");
    }

    // ============================================================================
    // TRANSFER TESTS
    // ============================================================================

    function test_Transfer_Success() public {
        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(user1, false);

        vm.prank(user1);
        nftContract.transferFrom(user1, user2, tokenId);

        assertEq(nftContract.ownerOf(tokenId), user2);
    }

    function test_Transfer_Unauthorized() public {
        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(user1, false);

        vm.prank(user2); // user2 tries to transfer user1's token
        vm.expectRevert(); // ERC721: caller is not token owner or approved
        nftContract.transferFrom(user1, user2, tokenId);
    }

    // ============================================================================
    // INTEGRATION TESTS
    // ============================================================================

    function test_FullPropertyLifecycle() public {
        // 1. Mint property
        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(user1, false);

        // 2. Transfer ownership
        vm.prank(user1);
        nftContract.transferFrom(user1, user2, tokenId);

        // 3. Update deed status
        vm.prank(address(controller));
        nftContract.setDeedHeldAtManageLife(tokenId, true);

        // 4. Verify final state
        assertEq(nftContract.ownerOf(tokenId), user2);
        assertTrue(nftContract.deedHeldAtManageLife(tokenId));
    }

    function test_MultipleTokens() public {
        // Mint multiple tokens
        vm.prank(address(controller));
        uint256 token1 = nftContract.mintPropertyNFT(user1, true);

        vm.prank(address(controller));
        uint256 token2 = nftContract.mintPropertyNFT(user2, false);

        vm.prank(address(controller));
        uint256 token3 = nftContract.mintPropertyNFT(user1, true);

        assertEq(token1, 1);
        assertEq(token2, 2);
        assertEq(token3, 3);
        assertEq(nftContract.totalSupply(), 3);

        assertTrue(nftContract.deedHeldAtManageLife(token1));
        assertFalse(nftContract.deedHeldAtManageLife(token2));
        assertTrue(nftContract.deedHeldAtManageLife(token3));
    }

    // 🔧 NEW INTEGRATION TESTS
    function test_ComplexPropertyTransferScenario() public {
        // Mint multiple tokens
        vm.prank(address(controller));
        uint256 token1 = nftContract.mintPropertyNFT(user1, true);
        vm.prank(address(controller));
        uint256 token2 = nftContract.mintPropertyNFT(user2, false);

        // user1 transfers token1 to user2
        vm.prank(user1);
        nftContract.transferFrom(user1, user2, token2);

        // user2 now owns both tokens
        assertEq(nftContract.ownerOf(token1), user2);
        assertEq(nftContract.ownerOf(token2), user2);

        // Update deed status on both
        vm.prank(address(controller));
        nftContract.setDeedHeldAtManageLife(token1, false);
        vm.prank(address(controller));
        nftContract.setDeedHeldAtManageLife(token2, true);

        assertFalse(nftContract.deedHeldAtManageLife(token1));
        assertTrue(nftContract.deedHeldAtManageLife(token2));
    }

    // ============================================================================
    // INVARIANT TESTS
    // ============================================================================

    function invariant_TotalSupplyEqualsTokenCount() public view {
        uint256 totalSupply = nftContract.totalSupply();
        uint256 actualCount = 0;

        // Count actual tokens (this is simplified - in practice you'd need to track minted tokens)
        for (uint256 i = 1; i <= totalSupply + 10; i++) {
            try nftContract.ownerOf(i) returns (address owner) {
                if (owner != address(0)) {
                    actualCount++;
                }
            } catch {
                break;
            }
        }

        assertEq(totalSupply, actualCount);
    }

    function invariant_UniqueTokenIds() public view {
        // Ensure no duplicate token IDs exist
        uint256 totalSupply = nftContract.totalSupply();

        for (uint256 i = 1; i <= totalSupply; i++) {
            address owner = nftContract.ownerOf(i);
            assertTrue(owner != address(0), "Token should exist");
        }
    }

    // ============================================================================
    // GAS OPTIMIZATION TESTS
    // ============================================================================

    function test_Gas_MintPropertyNFT() public {
        uint256 gasBefore = gasleft();

        vm.prank(address(controller));
        nftContract.mintPropertyNFT(user1, true);

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for minting:", gasUsed);

        // Ensure gas usage is reasonable (adjust threshold as needed)
        assertTrue(gasUsed < 200000, "Gas usage too high");
    }

    function test_Gas_TransferProperty() public {
        vm.prank(address(controller));
        uint256 tokenId = nftContract.mintPropertyNFT(user1, false);

        uint256 gasBefore = gasleft();
        vm.prank(user1);
        nftContract.transferFrom(user1, user2, tokenId);

        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for transfer:", gasUsed);

        assertTrue(gasUsed < 100000, "Gas usage too high");
    }
}
