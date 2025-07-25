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
    
    // ========== Purchase/Confirmation Errors ==========
    string constant E601 = "E601"; // Insufficient ETH sent
    string constant E602 = "E602"; // No pending purchase
    string constant E603 = "E603"; // Purchase not active
    string constant E604 = "E604"; // Not the seller
    string constant E605 = "E605"; // Confirmation period expired
    string constant E606 = "E606"; // Confirmation period not expired
    string constant E607 = "E607"; // Confirmation period too long
    string constant E608 = "E608"; // No additional payment required
    string constant E609 = "E609"; // Payment to seller failed
    string constant E610 = "E610"; // Payment to fee collector failed

    // ========== Bid Management Errors ==========
    string constant E701 = "E701"; // No active ETH bid found
    string constant E702 = "E702"; // Not in pending payment status
    string constant E703 = "E703"; // Payment deadline not expired
    string constant E704 = "E704"; // No pending refund
    string constant E705 = "E705"; // Refund withdrawal failed
    string constant E706 = "E706"; // Must send exact additional amount
    string constant E707 = "E707"; // Token transfer failed

    // ========== Timelock/MultiSig Errors ==========
    string constant E801 = "E801"; // Timelock required
    string constant E802 = "E802"; // MultiSig required
    string constant E803 = "E803"; // Invalid timelock
    string constant E804 = "E804"; // Invalid multisig

    // ========== Transfer Errors ==========
    string constant E901 = "E901"; // Token transfer failed
    string constant E902 = "E902"; // ETH refund failed
    string constant E903 = "E903"; // Payment to seller failed
    string constant E904 = "E904"; // Fee payment failed
    string constant E905 = "E905"; // ETH transfer failed
    string constant E906 = "E906"; // Payment deadline expired
    string constant E907 = "E907"; // No active bid found
    string constant E908 = "E908"; // Bid is not active
    string constant E909 = "E909"; // Not your bid
    string constant E910 = "E910"; // Not an ETH bid
    string constant E911 = "E911"; // Cannot change payment token with active bids
    string constant E912 = "E912"; // Unauthorized: admin role required
    string constant E913 = "E913"; // Invalid recipient address
    string constant E914 = "E914"; // Insufficient contract balance
    string constant E915 = "E915"; // Invalid token address
    string constant E916 = "E916"; // Insufficient token balance
}
