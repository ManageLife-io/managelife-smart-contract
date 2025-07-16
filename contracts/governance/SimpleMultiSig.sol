// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title SimpleMultiSig
/// @notice 简单的多签钱包，无时间锁，满足签名数量即刻执行
/// @dev 实现类似 Gnosis Safe 的核心功能，但更简单易用
contract SimpleMultiSig is ReentrancyGuard {

    /// @notice 默认交易有效期（7天）
    uint256 public constant DEFAULT_EXPIRY = 7 days;

    /// @notice 签名阈值（需要的最少签名数）
    uint256 public signaturesRequired;
    
    /// @notice 交易计数器，用于生成唯一交易ID
    uint256 public transactionCount;
    
    /// @notice 所有者地址数组
    address[] public owners;
    
    /// @notice 检查地址是否为所有者
    mapping(address => bool) public isOwner;
    
    /// @notice 交易结构体
    struct Transaction {
        address to;           // 目标地址
        uint256 value;        // 转账金额
        bytes data;           // 调用数据
        bool executed;        // 是否已执行
        uint256 confirmations; // 确认数量
        string description;   // 交易描述
        uint256 deadline;     // 交易截止时间
    }
    
    /// @notice 交易映射
    mapping(uint256 => Transaction) public transactions;
    
    /// @notice 交易确认映射 (交易ID => 所有者地址 => 是否确认)
    mapping(uint256 => mapping(address => bool)) public confirmations;
    
    /// @notice 事件
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event SignaturesRequiredChanged(uint256 signaturesRequired);
    event TransactionSubmitted(uint256 indexed transactionId, address indexed owner, string description);
    event TransactionConfirmed(uint256 indexed transactionId, address indexed owner);
    event TransactionRevoked(uint256 indexed transactionId, address indexed owner);
    event TransactionExecuted(uint256 indexed transactionId, address indexed executor, bool success);
    
    /// @notice 修饰符：仅所有者
    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }
    
    /// @notice 修饰符：仅多签钱包自己
    modifier onlyWallet() {
        require(msg.sender == address(this), "Only wallet can call");
        _;
    }

    /// @notice 修饰符：检查交易是否过期
    modifier notExpired(uint256 transactionId) {
        require(transactionId < transactionCount, "Transaction does not exist");
        require(block.timestamp <= transactions[transactionId].deadline, "Transaction expired");
        _;
    }
    
    /// @notice 构造函数
    /// @param _owners 初始所有者地址数组
    /// @param _signaturesRequired 需要的签名数量
    constructor(address[] memory _owners, uint256 _signaturesRequired) {
        require(_owners.length > 0, "Need at least one owner");
        require(_signaturesRequired > 0 && _signaturesRequired <= _owners.length, "Invalid signatures required");
        
        // 添加所有者
        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Invalid owner address");
            require(!isOwner[owner], "Duplicate owner");
            
            owners.push(owner);
            isOwner[owner] = true;
            emit OwnerAdded(owner);
        }
        
        signaturesRequired = _signaturesRequired;
        emit SignaturesRequiredChanged(_signaturesRequired);
    }
    
    /// @notice 提交新交易
    /// @param to 目标地址
    /// @param value 转账金额
    /// @param data 调用数据
    /// @param description 交易描述
    /// @return transactionId 交易ID
    function submitTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        string calldata description
    ) external onlyOwner returns (uint256 transactionId) {
        return submitTransactionWithDeadline(to, value, data, description, block.timestamp + DEFAULT_EXPIRY);
    }

    /// @notice 提交新交易（带自定义截止时间）
    /// @param to 目标地址
    /// @param value 转账金额
    /// @param data 调用数据
    /// @param description 交易描述
    /// @param deadline 交易截止时间
    /// @return transactionId 交易ID
    function submitTransactionWithDeadline(
        address to,
        uint256 value,
        bytes calldata data,
        string calldata description,
        uint256 deadline
    ) public onlyOwner returns (uint256 transactionId) {
        require(to != address(0), "Invalid target address");
        require(bytes(description).length > 0, "Description cannot be empty");
        require(deadline > block.timestamp, "Deadline must be in the future");
        require(deadline <= block.timestamp + 30 days, "Deadline too far in the future");

        transactionId = transactionCount;
        transactionCount++;

        transactions[transactionId] = Transaction({
            to: to,
            value: value,
            data: data,
            executed: false,
            confirmations: 0,
            description: description,
            deadline: deadline
        });

        emit TransactionSubmitted(transactionId, msg.sender, description);

        // 提交者自动确认
        confirmTransaction(transactionId);
    }
    
    /// @notice 确认交易
    /// @param transactionId 交易ID
    function confirmTransaction(uint256 transactionId) public onlyOwner notExpired(transactionId) {
        require(!transactions[transactionId].executed, "Transaction already executed");
        require(!confirmations[transactionId][msg.sender], "Transaction already confirmed");
        
        confirmations[transactionId][msg.sender] = true;
        transactions[transactionId].confirmations++;
        
        emit TransactionConfirmed(transactionId, msg.sender);
        
        // 如果达到签名阈值，立即执行
        if (transactions[transactionId].confirmations >= signaturesRequired) {
            executeTransaction(transactionId);
        }
    }
    
    /// @notice 撤销确认
    /// @param transactionId 交易ID
    function revokeConfirmation(uint256 transactionId) external onlyOwner notExpired(transactionId) {
        require(!transactions[transactionId].executed, "Transaction already executed");
        require(confirmations[transactionId][msg.sender], "Transaction not confirmed");
        
        confirmations[transactionId][msg.sender] = false;
        transactions[transactionId].confirmations--;
        
        emit TransactionRevoked(transactionId, msg.sender);
    }
    
    /// @notice 执行交易
    /// @param transactionId 交易ID
    function executeTransaction(uint256 transactionId) public nonReentrant notExpired(transactionId) {
        require(!transactions[transactionId].executed, "Transaction already executed");
        require(transactions[transactionId].confirmations >= signaturesRequired, "Not enough confirmations");

        Transaction storage txn = transactions[transactionId];

        // 执行交易
        (bool success, ) = txn.to.call{value: txn.value}(txn.data);

        if (success) {
            txn.executed = true;
            emit TransactionExecuted(transactionId, msg.sender, true);
        } else {
            // 执行失败，抛出异常但允许重试
            emit TransactionExecuted(transactionId, msg.sender, false);
            revert("Transaction execution failed");
        }
    }
    
    /// @notice 添加所有者（需要多签确认）
    /// @param owner 新所有者地址
    function addOwner(address owner) external onlyWallet {
        require(owner != address(0), "Invalid owner address");
        require(!isOwner[owner], "Already an owner");
        
        owners.push(owner);
        isOwner[owner] = true;
        
        emit OwnerAdded(owner);
    }
    
    /// @notice 移除所有者（需要多签确认）
    /// @param owner 要移除的所有者地址
    function removeOwner(address owner) external onlyWallet {
        require(isOwner[owner], "Not an owner");
        require(owners.length > signaturesRequired, "Cannot remove owner, would break threshold");
        
        // 从数组中移除
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        
        isOwner[owner] = false;
        
        emit OwnerRemoved(owner);
    }
    
    /// @notice 更改签名阈值（需要多签确认）
    /// @param _signaturesRequired 新的签名阈值
    function changeSignaturesRequired(uint256 _signaturesRequired) external onlyWallet {
        require(_signaturesRequired > 0 && _signaturesRequired <= owners.length, "Invalid signatures required");
        
        signaturesRequired = _signaturesRequired;
        
        emit SignaturesRequiredChanged(_signaturesRequired);
    }
    
    /// @notice 获取所有者列表
    /// @return 所有者地址数组
    function getOwners() external view returns (address[] memory) {
        return owners;
    }
    
    /// @notice 获取所有者数量
    /// @return 所有者数量
    function getOwnerCount() external view returns (uint256) {
        return owners.length;
    }
    
    /// @notice 获取交易详情
    /// @param transactionId 交易ID
    /// @return to 目标地址
    /// @return value 转账金额
    /// @return data 调用数据
    /// @return executed 是否已执行
    /// @return confirmationCount 确认数量
    /// @return description 交易描述
    /// @return deadline 交易截止时间
    function getTransaction(uint256 transactionId) external view returns (
        address to,
        uint256 value,
        bytes memory data,
        bool executed,
        uint256 confirmationCount,
        string memory description,
        uint256 deadline
    ) {
        Transaction storage txn = transactions[transactionId];
        return (
            txn.to,
            txn.value,
            txn.data,
            txn.executed,
            txn.confirmations,
            txn.description,
            txn.deadline
        );
    }
    
    /// @notice 检查交易是否被特定所有者确认
    /// @param transactionId 交易ID
    /// @param owner 所有者地址
    /// @return 是否已确认
    function isConfirmed(uint256 transactionId, address owner) external view returns (bool) {
        return confirmations[transactionId][owner];
    }
    
    /// @notice 检查交易是否可以执行
    /// @param transactionId 交易ID
    /// @return 是否可以执行
    function isExecutable(uint256 transactionId) external view returns (bool) {
        return transactionId < transactionCount &&
               !transactions[transactionId].executed &&
               transactions[transactionId].confirmations >= signaturesRequired &&
               block.timestamp <= transactions[transactionId].deadline;
    }

    /// @notice 检查交易是否已过期
    /// @param transactionId 交易ID
    /// @return 是否已过期
    function isExpired(uint256 transactionId) external view returns (bool) {
        return transactionId < transactionCount &&
               block.timestamp > transactions[transactionId].deadline;
    }
    
    /// @notice 接收ETH
    receive() external payable {}
    
    /// @notice 回退函数
    fallback() external payable {}
}