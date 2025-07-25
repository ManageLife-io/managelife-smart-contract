// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./PropertyTimelock.sol";

/// @title MultiSigOperator
/// @notice Multi-signature wallet for PropertyMarket operator functions
/// @dev Implements 3/5 multisig for operator role management as recommended for MA2-02 mitigation
contract MultiSigOperator is AccessControl, ReentrancyGuard {
    
    /// @notice Role for multisig signers
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
    
    /// @notice Minimum number of signatures required
    uint256 public constant REQUIRED_SIGNATURES = 3;
    
    /// @notice Maximum number of signers
    uint256 public constant MAX_SIGNERS = 5;
    
    /// @notice Current number of signers
    uint256 public signerCount;
    
    /// @notice Nonce for transaction uniqueness
    uint256 public nonce;
    
    /// @notice Timelock controller for delayed execution
    PropertyMarketTimelock public immutable timelock;
    
    /// @notice PropertyMarket contract address
    address public immutable propertyMarket;
    
    /// @notice Transaction structure
    struct Transaction {
        address target;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
        uint256 timestamp;
        string description;
    }
    
    /// @notice Mapping from transaction ID to transaction
    mapping(uint256 => Transaction) public transactions;
    
    /// @notice Mapping from transaction ID to signer to confirmation status
    mapping(uint256 => mapping(address => bool)) public confirmations;
    
    /// @notice Array of signer addresses for enumeration
    address[] public signers;
    
    /// @notice Events
    event TransactionSubmitted(uint256 indexed txId, address indexed submitter, string description);
    event TransactionConfirmed(uint256 indexed txId, address indexed signer);
    event TransactionRevoked(uint256 indexed txId, address indexed signer);
    event TransactionExecuted(uint256 indexed txId, address indexed executor);
    event SignerAdded(address indexed signer, address indexed admin);
    event SignerRemoved(address indexed signer, address indexed admin);
    
    /// @notice Constructor
    /// @param _timelock Address of the timelock controller
    /// @param _propertyMarket Address of the PropertyMarket contract
    /// @param _initialSigners Array of initial signer addresses
    /// @param _admin Address that can manage signers
    constructor(
        address _timelock,
        address _propertyMarket,
        address[] memory _initialSigners,
        address _admin
    ) {
        require(_timelock != address(0), "Invalid timelock address");
        require(_propertyMarket != address(0), "Invalid PropertyMarket address");
        require(_initialSigners.length >= REQUIRED_SIGNATURES, "Not enough initial signers");
        require(_initialSigners.length <= MAX_SIGNERS, "Too many initial signers");
        require(_admin != address(0), "Invalid admin address");
        
        timelock = PropertyMarketTimelock(payable(_timelock));
        propertyMarket = _propertyMarket;
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        
        // Add initial signers
        for (uint256 i = 0; i < _initialSigners.length; i++) {
            require(_initialSigners[i] != address(0), "Invalid signer address");
            _grantRole(SIGNER_ROLE, _initialSigners[i]);
            signers.push(_initialSigners[i]);
        }
        signerCount = _initialSigners.length;
    }
    
    /// @notice Submit a transaction for multi-signature approval
    /// @param target Target contract address
    /// @param value ETH value to send
    /// @param data Call data
    /// @param description Human-readable description
    /// @return txId Transaction ID
    function submitTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        string calldata description
    ) external onlyRole(SIGNER_ROLE) returns (uint256 txId) {
        require(target == propertyMarket, "Can only target PropertyMarket");
        
        txId = nonce++;
        transactions[txId] = Transaction({
            target: target,
            value: value,
            data: data,
            executed: false,
            confirmations: 0,
            timestamp: block.timestamp,
            description: description
        });
        
        emit TransactionSubmitted(txId, msg.sender, description);
        
        // Auto-confirm by submitter
        _confirmTransaction(txId);
    }
    
    /// @notice Confirm a transaction
    /// @param txId Transaction ID
    function confirmTransaction(uint256 txId) external onlyRole(SIGNER_ROLE) {
        require(transactions[txId].target != address(0), "Transaction does not exist");
        require(!transactions[txId].executed, "Transaction already executed");
        require(!confirmations[txId][msg.sender], "Transaction already confirmed by sender");
        
        _confirmTransaction(txId);
    }
    
    /// @notice Internal function to confirm transaction
    /// @param txId Transaction ID
    function _confirmTransaction(uint256 txId) internal {
        confirmations[txId][msg.sender] = true;
        transactions[txId].confirmations++;
        
        emit TransactionConfirmed(txId, msg.sender);
        
        // Auto-execute if enough confirmations
        if (transactions[txId].confirmations >= REQUIRED_SIGNATURES) {
            _executeTransaction(txId);
        }
    }
    
    /// @notice Revoke confirmation for a transaction
    /// @param txId Transaction ID
    function revokeConfirmation(uint256 txId) external onlyRole(SIGNER_ROLE) {
        require(transactions[txId].target != address(0), "Transaction does not exist");
        require(!transactions[txId].executed, "Transaction already executed");
        require(confirmations[txId][msg.sender], "Transaction not confirmed by sender");
        
        confirmations[txId][msg.sender] = false;
        transactions[txId].confirmations--;
        
        emit TransactionRevoked(txId, msg.sender);
    }
    
    /// @notice Execute a confirmed transaction through timelock
    /// @param txId Transaction ID
    function _executeTransaction(uint256 txId) internal nonReentrant {
        Transaction storage txn = transactions[txId];
        require(txn.confirmations >= REQUIRED_SIGNATURES, "Not enough confirmations");
        require(!txn.executed, "Transaction already executed");
        
        txn.executed = true;
        
        // Schedule operation in timelock
        bytes32 salt = keccak256(abi.encodePacked(txId, block.timestamp));
        timelock.scheduleSensitiveOperation(
            txn.target,
            txn.value,
            txn.data,
            bytes32(0), // no predecessor
            salt,
            txn.description
        );
        
        emit TransactionExecuted(txId, msg.sender);
    }
    
    /// @notice Add a new signer (admin only)
    /// @param signer Address of new signer
    function addSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(signer != address(0), "Invalid signer address");
        require(!hasRole(SIGNER_ROLE, signer), "Already a signer");
        require(signerCount < MAX_SIGNERS, "Maximum signers reached");
        
        _grantRole(SIGNER_ROLE, signer);
        signers.push(signer);
        signerCount++;
        
        emit SignerAdded(signer, msg.sender);
    }
    
    /// @notice Remove a signer (admin only)
    /// @param signer Address of signer to remove
    function removeSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(SIGNER_ROLE, signer), "Not a signer");
        require(signerCount > REQUIRED_SIGNATURES, "Cannot go below required signatures");
        
        _revokeRole(SIGNER_ROLE, signer);
        
        // Remove from signers array
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == signer) {
                signers[i] = signers[signers.length - 1];
                signers.pop();
                break;
            }
        }
        signerCount--;
        
        emit SignerRemoved(signer, msg.sender);
    }
    
    /// @notice Get transaction details
    /// @param txId Transaction ID
    /// @return target The target address
    /// @return value The ETH value
    /// @return data The transaction data
    /// @return executed Whether the transaction was executed
    /// @return confirmationCount Number of confirmations
    /// @return timestamp Transaction timestamp
    /// @return description Transaction description
    function getTransaction(uint256 txId) external view returns (
        address target,
        uint256 value,
        bytes memory data,
        bool executed,
        uint256 confirmationCount,
        uint256 timestamp,
        string memory description
    ) {
        Transaction storage txn = transactions[txId];
        return (
            txn.target,
            txn.value,
            txn.data,
            txn.executed,
            txn.confirmations,
            txn.timestamp,
            txn.description
        );
    }
    
    /// @notice Get all signers
    /// @return Array of signer addresses
    function getSigners() external view returns (address[] memory) {
        return signers;
    }
    
    /// @notice Check if transaction is confirmed by specific signer
    /// @param txId Transaction ID
    /// @param signer Signer address
    /// @return bool Confirmation status
    function isConfirmedBy(uint256 txId, address signer) external view returns (bool) {
        return confirmations[txId][signer];
    }
}
