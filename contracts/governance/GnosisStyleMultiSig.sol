// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title GnosisStyleMultiSig
/// @notice Gnosis Safe style multi-signature wallet without timelock
/// @dev Implements immediate execution once signature threshold is met
contract GnosisStyleMultiSig is ReentrancyGuard {
    using ECDSA for bytes32;

    /// @notice 签名长度常量
    uint256 private constant SIGNATURE_LENGTH = 65;

    /// @notice 最大所有者数量
    uint256 private constant MAX_OWNERS = 50;

    /// @notice Signature threshold (minimum signatures required)
    uint256 public threshold;
    
    /// @notice Current nonce for transaction uniqueness
    uint256 public nonce;
    
    /// @notice Array of owner addresses
    address[] public owners;
    
    /// @notice Mapping to check if address is owner
    mapping(address => bool) public isOwner;
    
    /// @notice Domain separator for EIP-712
    bytes32 public immutable DOMAIN_SEPARATOR;
    
    /// @notice Transaction typehash for EIP-712
    bytes32 public constant TRANSACTION_TYPEHASH = keccak256(
        "Transaction(address to,uint256 value,bytes data,uint256 nonce)"
    );
    
    /// @notice Events
    event ExecutionSuccess(bytes32 indexed txHash, uint256 payment);
    event ExecutionFailure(bytes32 indexed txHash, uint256 payment);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 threshold);
    
    /// @notice Errors
    error InvalidOwner();
    error InvalidThreshold();
    error DuplicateOwner();
    error NotEnoughOwners();
    error InvalidSignature();
    error TransactionFailed();
    error Unauthorized();
    
    /// @notice Constructor
    /// @param _owners Array of initial owner addresses
    /// @param _threshold Number of required signatures
    constructor(address[] memory _owners, uint256 _threshold) {
        if (_owners.length == 0) revert NotEnoughOwners();
        if (_threshold == 0 || _threshold > _owners.length) revert InvalidThreshold();
        
        // Set up domain separator for EIP-712
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GnosisStyleMultiSig")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                address(this)
            )
        );
        
        // Add owners
        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            if (owner == address(0) || isOwner[owner]) revert InvalidOwner();
            
            owners.push(owner);
            isOwner[owner] = true;
            emit OwnerAdded(owner);
        }
        
        threshold = _threshold;
        emit ThresholdChanged(_threshold);
    }
    
    /// @notice Execute transaction with signatures
    /// @param to Target contract address
    /// @param value ETH value to send
    /// @param data Transaction data
    /// @param signatures Concatenated signatures (65 bytes each)
    /// @return success Whether execution was successful
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        bytes calldata signatures
    ) external payable nonReentrant returns (bool success) {
        bytes32 txHash = getTransactionHash(to, value, data, nonce);
        nonce++;
        
        // Verify signatures
        _checkSignatures(txHash, signatures);
        
        // Execute transaction
        success = _execute(to, value, data);
        
        if (success) {
            emit ExecutionSuccess(txHash, 0);
        } else {
            emit ExecutionFailure(txHash, 0);
        }
    }
    
    /// @notice Internal function to execute transaction
    /// @param to Target address
    /// @param value ETH value
    /// @param data Transaction data
    /// @return success Execution result
    function _execute(
        address to,
        uint256 value,
        bytes memory data
    ) internal returns (bool success) {
        assembly {
            success := call(gas(), to, value, add(data, 0x20), mload(data), 0, 0)
        }
    }
    
    /// @notice Verify signatures for transaction
    /// @param txHash Transaction hash
    /// @param signatures Concatenated signatures
    function _checkSignatures(bytes32 txHash, bytes memory signatures) internal view {
        uint256 signatureCount = signatures.length / SIGNATURE_LENGTH;

        // 检查签名数量是否足够
        require(signatureCount >= threshold, "Not enough signatures");

        // Use array to track used signers (more gas efficient for small numbers)
        address[] memory usedSigners = new address[](signatureCount);
        address currentOwner;

        for (uint256 i = 0; i < signatureCount; i++) {
            bytes memory signature = _getSignature(signatures, i);
            // 使用 toEthSignedMessageHash 因为 JavaScript signMessage 会添加前缀
            currentOwner = txHash.toEthSignedMessageHash().recover(signature);

            // 检查是否为有效所有者
            require(isOwner[currentOwner], "Invalid owner");

            // 检查是否重复使用
            for (uint256 j = 0; j < i; j++) {
                require(usedSigners[j] != currentOwner, "Duplicate signature");
            }

            usedSigners[i] = currentOwner;
        }
    }
    
    /// @notice Extract individual signature from concatenated signatures
    /// @param signatures Concatenated signatures
    /// @param index Signature index
    /// @return signature Individual signature
    function _getSignature(bytes memory signatures, uint256 index) internal pure returns (bytes memory signature) {
        require(signatures.length >= (index + 1) * SIGNATURE_LENGTH, "Invalid signature index");

        signature = new bytes(SIGNATURE_LENGTH);
        uint256 offset = index * SIGNATURE_LENGTH;

        assembly {
            let src := add(add(signatures, 0x20), offset)
            let dest := add(signature, 0x20)

            // Copy 32 bytes (r)
            mstore(dest, mload(src))
            // Copy 32 bytes (s)
            mstore(add(dest, 0x20), mload(add(src, 0x20)))
            // Copy 1 byte (v)
            mstore8(add(dest, 0x40), byte(0, mload(add(src, 0x40))))
        }
    }
    
    /// @notice Get transaction hash for signing
    /// @param to Target address
    /// @param value ETH value
    /// @param data Transaction data
    /// @param _nonce Transaction nonce
    /// @return Transaction hash
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 _nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(TRANSACTION_TYPEHASH, to, value, keccak256(data), _nonce))
            )
        );
    }
    
    /// @notice Add new owner (requires multisig)
    /// @param owner New owner address
    /// @param _threshold New threshold
    function addOwnerWithThreshold(address owner, uint256 _threshold) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (owner == address(0) || isOwner[owner]) revert InvalidOwner();
        if (_threshold == 0 || _threshold > owners.length + 1) revert InvalidThreshold();
        
        owners.push(owner);
        isOwner[owner] = true;
        threshold = _threshold;
        
        emit OwnerAdded(owner);
        emit ThresholdChanged(_threshold);
    }
    
    /// @notice Remove owner (requires multisig)
    /// @param prevOwner Previous owner in linked list
    /// @param owner Owner to remove
    /// @param _threshold New threshold
    function removeOwner(address prevOwner, address owner, uint256 _threshold) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (!isOwner[owner]) revert InvalidOwner();
        if (owners.length - 1 < _threshold) revert InvalidThreshold();
        
        // Remove from owners array
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        
        isOwner[owner] = false;
        threshold = _threshold;
        
        emit OwnerRemoved(owner);
        emit ThresholdChanged(_threshold);
    }
    
    /// @notice Change threshold (requires multisig)
    /// @param _threshold New threshold
    function changeThreshold(uint256 _threshold) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (_threshold == 0 || _threshold > owners.length) revert InvalidThreshold();
        
        threshold = _threshold;
        emit ThresholdChanged(_threshold);
    }
    
    /// @notice Get all owners
    /// @return Array of owner addresses
    function getOwners() external view returns (address[] memory) {
        return owners;
    }
    
    /// @notice Get owner count
    /// @return Number of owners
    function getOwnerCount() external view returns (uint256) {
        return owners.length;
    }
    
    /// @notice Check if enough signatures are provided
    /// @param txHash Transaction hash
    /// @param signatures Signatures to check
    /// @return Whether signatures are valid and sufficient
    function checkSignatures(bytes32 txHash, bytes calldata signatures) external view returns (bool) {
        try this.validateSignatures(txHash, signatures) {
            return true;
        } catch {
            return false;
        }
    }
    
    /// @notice External wrapper for _checkSignatures (for testing)
    function validateSignatures(bytes32 txHash, bytes calldata signatures) external view {
        _checkSignatures(txHash, signatures);
    }
    
    /// @notice Receive ETH
    receive() external payable {}
    
    /// @notice Fallback function
    fallback() external payable {}
}