// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ErrorCodes - Compact error codes for gas optimization
/// @dev Short error codes to reduce contract size while maintaining clarity
library ErrorCodes {
    // ========== General Errors ==========
    string constant E001 = "E001"; // Invalid address
    string constant E002 = "E002"; // Unauthorized access
    string constant E003 = "E003"; // Invalid amount
    string constant E004 = "E004"; // Transfer failed
    string constant E005 = "E005"; // Payment failed
    
    // ========== Listing Errors ==========
    string constant E101 = "E101"; // Not available
    string constant E102 = "E102"; // Already listed
    string constant E103 = "E103"; // Not listed
    string constant E104 = "E104"; // Invalid price
    string constant E105 = "E105"; // Not owner
    
    // ========== Bidding Errors ==========
    string constant E201 = "E201"; // No active bid
    string constant E202 = "E202"; // Bid not active
    string constant E203 = "E203"; // Not your bid
    string constant E204 = "E204"; // Bid too low
    string constant E205 = "E205"; // Bid increment low
    string constant E206 = "E206"; // Must meet price
    string constant E207 = "E207"; // ETH amount mismatch
    string constant E208 = "E208"; // Insufficient allowance
    
    // ========== Payment Errors ==========
    string constant E301 = "E301"; // Token not allowed
    string constant E302 = "E302"; // Payment token mismatch
    string constant E303 = "E303"; // ETH refund failed
    string constant E304 = "E304"; // Excess refund failed
    
    // ========== Access Control Errors ==========
    string constant E401 = "E401"; // Not admin
    string constant E402 = "E402"; // Not operator
    string constant E403 = "E403"; // KYC required
    string constant E404 = "E404"; // Paused
    
    // ========== Validation Errors ==========
    string constant E501 = "E501"; // Invalid input
    string constant E502 = "E502"; // Out of range
    string constant E503 = "E503"; // Already exists
    string constant E504 = "E504"; // Not found
    
    // ========== Timelock/MultiSig Errors ==========
    string constant E601 = "E601"; // Timelock required
    string constant E602 = "E602"; // MultiSig required
    string constant E603 = "E603"; // Invalid timelock
    string constant E604 = "E604"; // Invalid multisig
}
