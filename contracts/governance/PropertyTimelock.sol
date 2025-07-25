// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title PropertyMarketTimelock
/// @notice Timelock controller for PropertyMarket privileged operations
/// @dev Implements 48-hour delay for sensitive operations as recommended for MA2-02 mitigation
contract PropertyMarketTimelock is TimelockController {
    
    /// @notice Minimum delay for operations (48 hours)
    uint256 public constant MIN_DELAY = 48 hours;
    
    /// @notice Event emitted when a sensitive operation is scheduled
    event SensitiveOperationScheduled(
        bytes32 indexed id,
        uint256 indexed delay,
        address indexed target,
        bytes4 selector,
        string operation
    );
    
    /// @notice Event emitted when a sensitive operation is executed
    event SensitiveOperationExecuted(
        bytes32 indexed id,
        address indexed target,
        bytes4 selector,
        string operation
    );
    
    /// @notice Constructor for PropertyMarketTimelock
    /// @param proposers Array of addresses that can propose operations
    /// @param executors Array of addresses that can execute operations (empty for open execution)
    /// @param admin Address that can grant/revoke roles (should be multisig)
    constructor(
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(MIN_DELAY, proposers, executors, admin) {
        // Additional setup if needed
    }
    
    /// @notice Schedule a sensitive PropertyMarket operation
    /// @param target The target contract address
    /// @param value The ETH value to send
    /// @param data The call data
    /// @param predecessor The predecessor operation hash
    /// @param salt The salt for unique operation ID
    /// @param operationName Human-readable operation name for transparency
    function scheduleSensitiveOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        string calldata operationName
    ) external onlyRole(PROPOSER_ROLE) {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        
        // Extract function selector for logging
        bytes4 selector = bytes4(data[:4]);
        
        // Schedule with minimum delay
        schedule(target, value, data, predecessor, salt, MIN_DELAY);
        
        emit SensitiveOperationScheduled(id, MIN_DELAY, target, selector, operationName);
    }
    
    /// @notice Execute a sensitive PropertyMarket operation
    /// @param target The target contract address
    /// @param value The ETH value to send
    /// @param data The call data
    /// @param predecessor The predecessor operation hash
    /// @param salt The salt for unique operation ID
    /// @param operationName Human-readable operation name for transparency
    function executeSensitiveOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        string calldata operationName
    ) external onlyRole(EXECUTOR_ROLE) {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        
        // Extract function selector for logging
        bytes4 selector = bytes4(data[:4]);
        
        // Execute the operation
        execute(target, value, data, predecessor, salt);
        
        emit SensitiveOperationExecuted(id, target, selector, operationName);
    }
    
    /// @notice Check if an operation is ready for execution
    /// @param target The target contract address
    /// @param value The ETH value to send
    /// @param data The call data
    /// @param predecessor The predecessor operation hash
    /// @param salt The salt for unique operation ID
    /// @return bool True if ready for execution
    function checkOperationReady(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external view returns (bool) {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        return isOperationReady(id);
    }
    
    /// @notice Get operation details for transparency
    /// @param target The target contract address
    /// @param value The ETH value to send
    /// @param data The call data
    /// @param predecessor The predecessor operation hash
    /// @param salt The salt for unique operation ID
    /// @return timestamp When the operation can be executed
    function getOperationTimestamp(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external view returns (uint256 timestamp) {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        return getTimestamp(id);
    }
}
