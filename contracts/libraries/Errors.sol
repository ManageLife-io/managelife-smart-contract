// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title Errors - Centralized error message library
/// @notice Provides standardized error messages across all contracts
/// @dev Library to ensure consistent error handling and reduce code duplication
library Errors {
    
    // ========== General Errors ==========
    string constant ZERO_ADDRESS = "Zero address not allowed";
    string constant INVALID_ADDRESS = "Invalid address";
    string constant INVALID_AMOUNT = "Invalid amount";
    string constant INSUFFICIENT_BALANCE = "Insufficient balance";
    string constant UNAUTHORIZED_ACCESS = "Unauthorized access";
    string constant OPERATION_FAILED = "Operation failed";
    
    // ========== Access Control Errors ==========
    string constant NOT_OWNER = "Not the owner";
    string constant NOT_OPERATOR = "Operator required";
    string constant NOT_REBASER = "Caller is not the rebaser";
    string constant NOT_DISTRIBUTOR = "Caller is not the distributor";
    string constant KYC_REQUIRED = "KYC required";
    
    // ========== Token Errors ==========
    string constant INVALID_TOKEN = "Invalid token";
    string constant TOKEN_NOT_ALLOWED = "Payment token not allowed";
    string constant INSUFFICIENT_ALLOWANCE = "Insufficient token allowance";
    string constant TRANSFER_FAILED = "Transfer failed";
    string constant MINT_FAILED = "Mint failed";
    string constant BURN_FAILED = "Burn failed";
    
    // ========== NFT Errors ==========
    string constant NOT_NFT_OWNER = "Not NFT owner";
    string constant NFT_NOT_EXISTS = "NFT does not exist";
    string constant NFT_ALREADY_EXISTS = "NFT already exists";
    string constant INVALID_TOKEN_ID = "Invalid token ID";
    
    // ========== Market Errors ==========
    string constant NOT_LISTED = "Property not listed";
    string constant NOT_AVAILABLE = "Not available";
    string constant ALREADY_LISTED = "Already listed";
    string constant INVALID_PRICE = "Invalid price";
    string constant PAYMENT_FAILED = "Payment failed";
    string constant NOT_SELLER = "Not the seller";
    string constant CANNOT_BID_OWN_LISTING = "Cannot bid on your own listing";
    string constant ETH_AMOUNT_MISMATCH = "ETH amount mismatch";
    string constant ETH_REFUND_FAILED = "ETH refund failed";
    string constant BID_MUST_MEET_PRICE = "Bid must meet listing price";
    string constant NO_BIDS_AVAILABLE = "No bids available";
    string constant NO_PENDING_PAYMENT = "No pending payment";
    string constant EXCESS_REFUND_FAILED = "Excess refund failed";
    string constant BID_INCREMENT_LOW = "Bid increment too low";
    string constant BID_AMOUNT_TOO_LARGE = "Bid amount too large";
    string constant CANNOT_CHANGE_TOKEN = "Cannot change payment token";
    string constant ETH_DEFAULT_ALLOWED = "ETH is allowed by default";
    string constant CANNOT_REMOVE_ETH = "Cannot remove ETH as payment method";
    
    // ========== Bidding Errors ==========
    string constant NO_ACTIVE_BID = "No active bid found";
    string constant BID_NOT_ACTIVE = "Bid is not active";
    string constant NOT_YOUR_BID = "Not your bid";
    string constant INVALID_BID_INDEX = "Invalid bid index";
    string constant BID_TOO_LOW = "Bid too low";
    string constant BIDDER_MISMATCH = "Bidder mismatch";
    string constant AMOUNT_MISMATCH = "Amount mismatch";
    string constant PAYMENT_TOKEN_MISMATCH = "Payment token mismatch";
    string constant INSUFFICIENT_ETH_DEPOSIT = "Insufficient ETH deposit";
    
    // ========== Staking Errors ==========
    string constant INSUFFICIENT_STAKE = "Insufficient stake";
    string constant STAKING_PERIOD_NOT_MET = "Staking period not met";
    string constant ALREADY_STAKED = "Already staked";
    string constant NOT_STAKED = "Not staked";
    string constant REWARD_CALCULATION_FAILED = "Reward calculation failed";
    string constant CLAIM_FAILED = "Claim failed";
    
    // ========== Rebase Errors ==========
    string constant REBASE_TOO_SOON = "Rebase too soon";
    string constant INVALID_REBASE_FACTOR = "Invalid rebase factor";
    string constant REBASE_FAILED = "Rebase failed";
    string constant SUPPLY_LIMIT_EXCEEDED = "Supply limit exceeded";
    string constant BELOW_MIN_SUPPLY = "Below minimum supply";
    
    // ========== Configuration Errors ==========
    string constant INVALID_CONFIGURATION = "Invalid configuration";
    string constant RATE_TOO_HIGH = "Rate too high";
    string constant PERIOD_TOO_SHORT = "Period too short";
    string constant PERIOD_TOO_LONG = "Period too long";
    string constant COOLDOWN_NOT_MET = "Cooldown not met";
    string constant PAUSED = "Contract is paused";
    
    // ========== Payment Errors ==========
    string constant INSUFFICIENT_ETH_SENT = "Insufficient ETH sent";
    string constant PAYMENT_TO_SELLER_FAILED = "Payment to seller failed";
    string constant FEE_PAYMENT_FAILED = "Fee payment failed";
    string constant REFUND_FAILED = "Refund failed";
    string constant TRANSFER_TO_SELLER_FAILED = "Transfer to seller failed";
    string constant FEE_TRANSFER_FAILED = "Fee transfer failed";
    
    // ========== Validation Errors ==========
    string constant INVALID_SIGNATURE = "Invalid signature";
    string constant EXPIRED = "Expired";
    string constant ALREADY_USED = "Already used";
    string constant INVALID_PROOF = "Invalid proof";
    string constant OUT_OF_BOUNDS = "Out of bounds";
    string constant ARRAY_LENGTH_MISMATCH = "Array length mismatch";

    // ========== MA2-02 Mitigation Errors ==========
    string constant TIMELOCK_NOT_SET = "Timelock not configured";
    string constant MULTISIG_NOT_SET = "MultiSig not configured";
    string constant INVALID_TIMELOCK = "Invalid timelock address";
    string constant INVALID_MULTISIG = "Invalid multisig address";
    string constant TIMELOCK_ALREADY_SET = "Timelock already configured";
    string constant MULTISIG_ALREADY_SET = "MultiSig already configured";
    string constant MUST_USE_TIMELOCK = "Must be called through timelock";

    // ========== Bidding Mechanism Fix Errors ==========
    string constant MUST_OUTBID_HIGHEST = "Must exceed highest active bid";
    string constant PURCHASE_AMOUNT_MISMATCH = "Purchase amount mismatch";
    // Note: TRANSFER_FAILED and EXCESS_REFUND_FAILED already defined above
}