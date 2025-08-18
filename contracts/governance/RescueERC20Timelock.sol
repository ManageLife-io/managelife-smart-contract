// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdminControl} from "../interfaces/IAdminControl.sol";

/**
 * @title RescueERC20Timelock
 * @notice Stateful, inheritable timelocked "rescue" (emergency withdrawal) module for ETH (address(0))
 *         and ERC20 tokens. Use it as a base in product contracts (e.g., PropertyMarket).
 *
 *         Flow:
 *           - requestRescue(asset, amount, to, memo) -> queues an op; ETA = now + rescueDelay
 *           - executeRescue(opId)                    -> after ETA; transfers funds
 *           - cancelRescue(opId)                     -> can cancel before execution
 *
 *         Roles are **externalized** via a generic authority (AdminControl-compatible).
 *         Provide your AdminControl address in the constructor and grant these roles there:
 *           RESCUE_REQUESTER_ROLE, RESCUE_EXECUTOR_ROLE, RESCUE_CANCELER_ROLE, RESCUE_PARAM_MANAGER_ROLE
 *
 *         Child contracts may override _beforeRescue/_afterRescue (no-ops by default) to enforce local invariants.
 *         This contract is NON-ABSTRACT and owns its own storage.
 */
contract RescueERC20Timelock is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    // Role authority (AdminControl/OZ AccessControl compatible)
    // ─────────────────────────────────────────────────────────────────────────────


    /// @notice Authority used for role checks (e.g., your AdminControl).
    IRoleAuthority public rescueAuthority;

    // ─────────────────────────────────────────────────────────────────────────────
    // Roles to grant in your AdminControl
    // ─────────────────────────────────────────────────────────────────────────────
    bytes32 public constant RESCUE_REQUESTER_ROLE     = keccak256("RESCUE_REQUESTER_ROLE");
    bytes32 public constant RESCUE_EXECUTOR_ROLE      = keccak256("RESCUE_EXECUTOR_ROLE");
    bytes32 public constant RESCUE_CANCELER_ROLE      = keccak256("RESCUE_CANCELER_ROLE");
    bytes32 public constant RESCUE_PARAM_MANAGER_ROLE = keccak256("RESCUE_PARAM_MANAGER_ROLE");

    // ─────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────
    struct RescueOp {
        address asset;   // address(0) = ETH
        address to;
        uint256 amount;
        uint64  eta;     // earliest execution time
        bool    exists;
    }

    /// @notice Delay applied to new requests (seconds).
    uint256 public rescueDelay;

    /// @notice Sequential nonce to create unique opIds.
    uint256 private _rescueNonce;

    /// @notice Queued operations by opId.
    mapping(bytes32 => RescueOp) public rescueOps;

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────
    event RescueAuthoritySet(address indexed oldAuthority, address indexed newAuthority);
    event RescueDelaySet(uint256 oldDelay, uint256 newDelay);

    event RescueRequested(
        bytes32 indexed opId,
        address indexed asset,
        address indexed to,
        uint256 amount,
        uint64  eta,
        string  memo
    );

    event RescueExecuted(
        bytes32 indexed opId,
        address indexed asset,
        address indexed to,
        uint256 amount
    );

    event RescueCanceled(
        bytes32 indexed opId,
        address indexed asset,
        address indexed to,
        uint256 amount
    );

    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────
    error Unauthorized();
    error InvalidAuthority();
    error InvalidRecipient();
    error InvalidAmount();
    error OpAlreadyExists();
    error OpNotFound();
    error NotReady(uint64 eta);
    error InsufficientBalance();

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────
    /**
     * @param authority  AdminControl/AccessControl authority for roles.
     * @param delay      Initial timelock delay in seconds.
     */
    constructor(IRoleAuthority authority, uint256 delay) {
        if (address(authority) == address(0)) revert InvalidAuthority();
        rescueAuthority = authority;
        rescueDelay = delay;
        emit RescueAuthoritySet(address(0), address(authority));
        emit RescueDelaySet(0, delay);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin params
    // ─────────────────────────────────────────────────────────────────────────────
    function setRescueAuthority(IRoleAuthority newAuthority) external onlyRescueParamManager {
        if (address(newAuthority) == address(0)) revert InvalidAuthority();
        address old = address(rescueAuthority);
        rescueAuthority = newAuthority;
        emit RescueAuthoritySet(old, address(newAuthority));
    }

    function setRescueDelay(uint256 newDelay) external onlyRescueParamManager {
        uint256 old = rescueDelay;
        rescueDelay = newDelay;
        emit RescueDelaySet(old, newDelay);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Core queue/execute/cancel
    // ─────────────────────────────────────────────────────────────────────────────
    /**
     * @notice Queue a rescue operation for ETH (asset=address(0)) or an ERC20 token.
     * @param asset  address(0) for ETH, or ERC20 token address
     * @param amount amount to rescue
     * @param to     recipient
     * @param memo   free-form note for off-chain ops (not used in id)
     * @return opId  operation identifier
     */
    function requestRescue(address asset, uint256 amount, address to, string calldata memo)
        external
        onlyRescueRequester
        returns (bytes32 opId)
    {
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();

        // compute opId with current nonce to make it unique per request
        uint256 nextNonce = _rescueNonce + 1;
        opId = _computeOpId(asset, amount, to, nextNonce);

        if (rescueOps[opId].exists) revert OpAlreadyExists();

        uint64 eta = uint64(block.timestamp + rescueDelay);
        rescueOps[opId] = RescueOp({
            asset: asset,
            to: to,
            amount: amount,
            eta: eta,
            exists: true
        });

        _rescueNonce = nextNonce;

        emit RescueRequested(opId, asset, to, amount, eta, memo);
    }

    /**
     * @notice Execute a queued rescue after its ETA.
     */
    function executeRescue(bytes32 opId) external nonReentrant onlyRescueExecutor {
        RescueOp memory op = rescueOps[opId];
        if (!op.exists) revert OpNotFound();
        if (block.timestamp < op.eta) revert NotReady(op.eta);

        _beforeRescue(op.asset, op.amount, op.to);

        if (op.asset == address(0)) {
            // ETH
            if (address(this).balance < op.amount) revert InsufficientBalance();
            (bool ok, ) = payable(op.to).call{value: op.amount}("");
            require(ok, "ETH transfer failed");
        } else {
            // ERC20
            IERC20(op.asset).safeTransfer(op.to, op.amount);
        }

        delete rescueOps[opId];

        emit RescueExecuted(opId, op.asset, op.to, op.amount);

        _afterRescue(op.asset, op.amount, op.to);
    }

    /**
     * @notice Cancel a queued rescue (anytime before execution).
     */
    function cancelRescue(bytes32 opId) external onlyRescueCanceler {
        RescueOp memory op = rescueOps[opId];
        if (!op.exists) revert OpNotFound();

        delete rescueOps[opId];
        emit RescueCanceled(opId, op.asset, op.to, op.amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views & helpers
    // ─────────────────────────────────────────────────────────────────────────────
    function previewOpId(address asset, uint256 amount, address to) external view returns (bytes32) {
        return _computeOpId(asset, amount, to, _rescueNonce + 1);
    }

    function rescueNonce() external view returns (uint256) {
        return _rescueNonce;
    }

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
    // Hooks (optional overrides in children). No-ops here so contract is non-abstract.
    // ─────────────────────────────────────────────────────────────────────────────
    /**
     * @dev Enforce product-specific safety (e.g., forbid draining escrowed payment tokens while
     *      there are pending purchases). REVERT to block execution.
     */
    function _beforeRescue(address /*asset*/, uint256 /*amount*/, address /*to*/) internal view virtual {}

    /**
     * @dev Post-transfer hook (e.g., emit product-specific events or sync accounting).
     */
    function _afterRescue(address /*asset*/, uint256 /*amount*/, address /*to*/) internal virtual {}

    // ─────────────────────────────────────────────────────────────────────────────
    // Auth
    // ─────────────────────────────────────────────────────────────────────────────
    modifier onlyRescueRequester() {
        if (!_isAuthorized(RESCUE_REQUESTER_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyRescueExecutor() {
        if (!_isAuthorized(RESCUE_EXECUTOR_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyRescueCanceler() {
        if (!_isAuthorized(RESCUE_CANCELER_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyRescueParamManager() {
        if (!_isAuthorized(RESCUE_PARAM_MANAGER_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    function _isAuthorized(bytes32 role, address account) internal view returns (bool) {
        IRoleAuthority auth = rescueAuthority;
        return auth.hasRole(role, account) || auth.hasRole(auth.DEFAULT_ADMIN_ROLE(), account);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Receive ETH (optional: child may override/restrict)
    // ─────────────────────────────────────────────────────────────────────────────
    receive() external payable {}
}
