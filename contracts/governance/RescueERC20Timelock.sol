// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdminControl} from "../interfaces/IAdminControl.sol";

/**
 * @title RescueERC20Timelock
 * @author Jose Herrera
 * @notice A timelock-based ERC20 token rescue mechanism with role-based access control.
 * @dev This contract provides a secure way to rescue ERC20 tokens from contracts through
 *      a time-delayed execution pattern. It is designed to be inherited by any contract
 *      that holds ERC20 tokens and needs emergency rescue capabilities.
 * 
 *      Key Features:
 *      - Time-delayed execution with configurable delay from AdminControl
 *      - Role-based access control through AdminControl's ERC20_RESCUE_ROLE
 *      - Automatic cancellation of rescues that cannot be fulfilled
 *      - Support for rebasing tokens (no balance validation during queueing)
 *      - Reentrancy protection on execution
 *      - Unique operation IDs to prevent replay attacks
 * 
 *      Security Considerations:
 *      - Rebasing tokens are supported in theory but no specific checks are performed
 *      - Rescues that cannot be fulfilled due to insufficient balance are automatically cancelled
 *      - Each rescue operation is uniquely identified by asset, amount, recipient, and nonce
 * 
 *      Usage:
 *      This contract should be inherited by any contract that:
 *      1. Holds ERC20 tokens that might need emergency rescue
 *      2. Requires time-delayed token recovery mechanisms
 *      3. Needs role-based access control for token operations
 * 
 */
contract RescueERC20Timelock is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Admin control contract that manages roles and timelock delays
    /// @dev Used to verify ERC20_RESCUE_ROLE permissions and get rescue delay configuration
    IAdminControl public adminControl;

    // ─────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────
    
    /**
     * @notice Structure representing a queued rescue operation
     * @param asset The ERC20 token contract address to rescue from
     * @param to The recipient address that will receive the rescued tokens
     * @param amount The amount of tokens to rescue (in token's native decimals)
     * @param executableAt The timestamp when this operation becomes executable
     */
    struct RescueOp {
        address asset;
        address to;
        uint256 amount;
        uint64  executableAt;
    }

    /// @notice Sequential nonce to create unique operation IDs
    /// @dev Incremented for each rescue request to ensure unique opIds across all operations
    uint256 private _rescueNonce;

    /// @notice Mapping of operation ID to rescue operation details
    /// @dev Maps keccak256 hash of (chainid, contract, asset, to, amount, nonce) to RescueOp struct
    mapping(bytes32 => RescueOp) public rescueOps;

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Emitted when a rescue operation is queued
     * @param opId Unique operation identifier
     * @param asset ERC20 token address to be rescued
     * @param to Recipient address for the rescued tokens
     * @param amount Amount of tokens to rescue (in token's native decimals)
     * @param executableAt Timestamp when the operation becomes executable
     * @param memo Optional memo string for off-chain tracking (not used in opId generation)
     */
    event RescueRequested(
        bytes32 indexed opId,
        address indexed asset,
        address indexed to,
        uint256 amount,
        uint64  executableAt,
        string  memo
    );

    /**
     * @notice Emitted when a rescue operation is successfully executed
     * @param opId Unique operation identifier that was executed
     * @param asset ERC20 token address that was rescued
     * @param to Recipient address that received the tokens
     * @param amount Amount of tokens that were transferred
     */
    event RescueExecuted(
        bytes32 indexed opId,
        address indexed asset,
        address indexed to,
        uint256 amount
    );

    /**
     * @notice Emitted when a rescue operation is cancelled
     * @param opId Unique operation identifier that was cancelled
     * @param asset ERC20 token address that was supposed to be rescued
     * @param to Recipient address that would have received the tokens
     * @param amount Amount of tokens that were supposed to be rescued
     * @param reason The reason for cancellation (manual or insufficient balance)
     */
    event RescueCanceled(
        bytes32 indexed opId,
        address indexed asset,
        address indexed to,
        uint256 amount,
        RescueCancelReason reason
    );

    /**
     * @notice Enumeration of possible rescue cancellation reasons
     * @param NOT_ENOUGH_BALANCE_TO_RESCUE Automatic cancellation due to insufficient token balance
     * @param MANUAL_CANCEL_BY_RESCUER Manual cancellation by authorized rescuer
     */
    enum RescueCancelReason {
        NOT_ENOUGH_BALANCE_TO_RESCUE,
        MANUAL_CANCEL_BY_RESCUER
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────
    
    /// @notice Thrown when caller lacks required ERC20_RESCUE_ROLE permission
    error Unauthorized();
    
    /// @notice Thrown when a zero address is provided where a valid address is required
    error ZeroAddress();
    
    /// @notice Thrown when an invalid amount (zero or negative) is provided
    error InvalidAmount();
    
    /// @notice Thrown when attempting to create an operation that already exists
    error OpAlreadyExists();
    
    /// @notice Thrown when attempting to operate on a non-existent operation ID
    error OpNotFound();
    
    /// @notice Thrown when attempting to execute an operation before its execution time
    /// @param executableAt The timestamp when the operation becomes executable
    error NotReady(uint64 executableAt);

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────
    
    /**
     * @notice Initializes the RescueERC20Timelock contract
     * @param _adminControl The AdminControl contract that manages roles and timelock delays
     * @dev Sets up the admin control reference for role verification and delay configuration
     * @custom:throws ZeroAddress if _adminControl is the zero address
     */
    constructor(IAdminControl _adminControl) {
        if (address(_adminControl) == address(0)) revert ZeroAddress();
        adminControl = _adminControl;
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // Core queue/execute/cancel
    // ─────────────────────────────────────────────────────────────────────────────
    /**
     * @notice Queue a rescue operation for an ERC20 token with time-delayed execution
     * @param asset The ERC20 token contract address to rescue tokens from
     * @param amount The amount of tokens to rescue (in token's native decimals)
     * @param to The recipient address that will receive the rescued tokens
     * @param memo Optional memo string for off-chain tracking and identification
     * @return opId Unique operation identifier for tracking and execution
     * @dev Creates a time-locked rescue operation that can be executed after the delay period.
     *      The delay is configured in AdminControl.erc20RescueDelay().
     *      No balance validation is performed at queueing time, supporting rebasing tokens.
     *      Operations that cannot be fulfilled will be automatically cancelled during execution.
     * @custom:throws Unauthorized if caller lacks ERC20_RESCUE_ROLE
     * @custom:throws ZeroAddress if asset or to address is zero
     * @custom:throws InvalidAmount if amount is zero
     */
    function requestRescue(address asset, uint256 amount, address to, string calldata memo)
        external
        onlyRescuer
        nonReentrant
        returns (bytes32 opId)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if(asset==address(0)){
            revert ZeroAddress();
        }

        // compute opId with current nonce to make it unique per request
        uint256 nextNonce = ++_rescueNonce;
        opId = _computeOpId(asset, amount, to, nextNonce);

        uint64 _eta = uint64(block.timestamp + adminControl.erc20RescueDelay());
        rescueOps[opId] = RescueOp({
            asset: asset,
            to: to,
            amount: amount,
            executableAt: _eta
        });

        emit RescueRequested(opId, asset, to, amount, _eta, memo);
    }

    /**
     * @notice Execute a queued rescue operation after its execution time has passed
     * @param opId The unique operation identifier of the rescue to execute
     * @dev Executes the rescue if sufficient balance exists, otherwise cancels automatically.
     *      This approach supports rebasing tokens by checking balance at execution time.
     *      Uses SafeERC20 for secure token transfers with reentrancy protection.
     *      The operation is deleted from storage regardless of success or failure.
     * @custom:throws Unauthorized if caller lacks ERC20_RESCUE_ROLE
     * @custom:throws OpNotFound if operation ID doesn't exist
     * @custom:throws NotReady if current timestamp is before executableAt
     */
    function executeRescue(bytes32 opId) external nonReentrant onlyRescuer {
        RescueOp memory op = rescueOps[opId];
        if (op.asset == address(0)) revert OpNotFound();
        if (block.timestamp < op.executableAt) revert NotReady(op.executableAt);
        if(IERC20(op.asset).balanceOf(address(this)) >= op.amount){
            IERC20(op.asset).safeTransfer(op.to, op.amount);
            emit RescueExecuted(opId, op.asset, op.to, op.amount);
        }else{//Not enough balance to rescue, auto cancel.
            emit RescueCanceled(opId, op.asset, op.to, op.amount, RescueCancelReason.NOT_ENOUGH_BALANCE_TO_RESCUE);
        }
        delete rescueOps[opId];
    }

    /**
     * @notice Manually cancel a queued rescue operation before execution
     * @param opId The unique operation identifier of the rescue to cancel
     * @dev Allows authorized rescuers to cancel operations at any time before execution.
     *      This provides flexibility to handle changed circumstances or incorrect requests.
     *      The operation is permanently removed from storage and cannot be recovered.
     * @custom:throws Unauthorized if caller lacks ERC20_RESCUE_ROLE
     * @custom:throws OpNotFound if operation ID doesn't exist
     */
    function cancelRescue(bytes32 opId) external nonReentrant onlyRescuer {
        RescueOp memory op = rescueOps[opId];
        if (op.asset == address(0)) revert OpNotFound();

        delete rescueOps[opId];
        emit RescueCanceled(opId, op.asset, op.to, op.amount, RescueCancelReason.MANUAL_CANCEL_BY_RESCUER);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views & helpers
    // ─────────────────────────────────────────────────────────────────────────────
    
    /**
     * @notice Preview the operation ID that would be generated for the next rescue request
     * @param asset The ERC20 token contract address
     * @param amount The amount of tokens to rescue
     * @param to The recipient address
     * @return The operation ID that would be generated for these parameters
     * @dev Useful for front-end applications to predict operation IDs before submission
     */
    function previewOpId(address asset, uint256 amount, address to) external view returns (bytes32) {
        return _computeOpId(asset, amount, to, _rescueNonce + 1);
    }

    /**
     * @notice Get the current rescue nonce value
     * @return The current nonce used for generating unique operation IDs
     * @dev The nonce increments with each rescue request to ensure uniqueness
     */
    function rescueNonce() external view returns (uint256) {
        return _rescueNonce;
    }

    /**
     * @notice Internal function to compute a unique operation ID
     * @param asset The ERC20 token contract address
     * @param amount The amount of tokens to rescue
     * @param to The recipient address
     * @param nonce_ The nonce value to ensure uniqueness
     * @return The computed operation ID as a keccak256 hash
     * @dev Creates a unique identifier by hashing chain ID, contract address, 
     *      operation parameters, and nonce. This prevents replay attacks across
     *      different chains and contract instances.
     */
    function _computeOpId(address asset, uint256 amount, address to, uint256 nonce_)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(uint256(block.chainid), address(this), asset, to, amount, nonce_)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Auth
    // ─────────────────────────────────────────────────────────────────────────────
    
    /**
     * @notice Modifier to restrict access to authorized rescuers only
     * @dev Checks if the caller has the ERC20_RESCUE_ROLE through AdminControl
     * @custom:throws Unauthorized if caller lacks the required role
     */
    modifier onlyRescuer() {
        if (!adminControl.hasRole(adminControl.ERC20_RESCUE_ROLE(), msg.sender)) revert Unauthorized();
        _;
    }
}
