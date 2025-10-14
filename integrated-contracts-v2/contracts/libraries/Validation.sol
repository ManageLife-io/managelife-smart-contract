// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./Errors.sol";

/// @title Validation - Centralized validation library
/// @notice Provides common validation functions across all contracts
/// @dev Library to ensure consistent validation logic and reduce code duplication
library Validation {
    
    /// @notice Validates that an address is not zero
    /// @param addr The address to validate
    function validateNonZeroAddress(address addr) internal pure {
        require(addr != address(0), Errors.ZERO_ADDRESS);
    }
    
    /// @notice Validates that an amount is greater than zero
    /// @param amount The amount to validate
    function validatePositiveAmount(uint256 amount) internal pure {
        require(amount > 0, Errors.INVALID_AMOUNT);
    }
    
    /// @notice Validates that two addresses are different
    /// @param addr1 First address
    /// @param addr2 Second address
    function validateDifferentAddresses(address addr1, address addr2) internal pure {
        require(addr1 != addr2, "Addresses must be different");
    }
    
    /// @notice Validates that an array is not empty
    /// @param length The length of the array
    function validateNonEmptyArray(uint256 length) internal pure {
        require(length > 0, "Array cannot be empty");
    }
    
    /// @notice Validates that two arrays have the same length
    /// @param length1 Length of first array
    /// @param length2 Length of second array
    function validateArrayLengths(uint256 length1, uint256 length2) internal pure {
        require(length1 == length2, Errors.ARRAY_LENGTH_MISMATCH);
    }
    
    /// @notice Validates that a percentage is within valid range (0-10000 basis points)
    /// @param percentage The percentage in basis points
    function validatePercentage(uint256 percentage) internal pure {
        require(percentage <= 10000, "Percentage too high");
    }
    
    /// @notice Validates that a timestamp is in the future
    /// @param timestamp The timestamp to validate
    function validateFutureTimestamp(uint256 timestamp) internal view {
        require(timestamp > block.timestamp, "Timestamp must be in future");
    }
    
    /// @notice Validates that a timestamp is not expired
    /// @param timestamp The timestamp to validate
    function validateNotExpired(uint256 timestamp) internal view {
        require(timestamp >= block.timestamp, Errors.EXPIRED);
    }
    
    /// @notice Validates that an index is within bounds
    /// @param index The index to validate
    /// @param maxIndex The maximum valid index (exclusive)
    function validateIndex(uint256 index, uint256 maxIndex) internal pure {
        require(index < maxIndex, Errors.OUT_OF_BOUNDS);
    }
    
    /// @notice Validates that a value is within a specified range
    /// @param value The value to validate
    /// @param min Minimum allowed value (inclusive)
    /// @param max Maximum allowed value (inclusive)
    function validateRange(uint256 value, uint256 min, uint256 max) internal pure {
        require(value >= min && value <= max, "Value out of range");
    }
}