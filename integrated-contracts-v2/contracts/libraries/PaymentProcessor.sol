// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PaymentProcessor - Centralized payment processing library
/// @notice Handles ERC20 token payments with fee calculation
/// @dev Library to consolidate payment logic across contracts
library PaymentProcessor {
        using SafeERC20 for IERC20;

    /// @notice Configuration for payment processing
    struct PaymentConfig {
        uint256 baseFee;        // Fee percentage in basis points
        address feeCollector;   // Address to receive fees
        uint256 percentageBase; // Base for percentage calculations (e.g., 10000 for basis points)
    }
    
    /// @notice Emitted when a payment is processed
    event PaymentProcessed(
        address indexed seller,
        address indexed buyer,
        uint256 amount,
        uint256 fees,
        address paymentToken
    );
    
    /// @notice Processes payment for transactions
    /// @dev Handles ERC20 token payments with proper fee calculation
    /// @param config Payment configuration containing fee settings
    /// @param seller Address of the payment recipient
    /// @param buyer Address of the payment sender
    /// @param amount Total payment amount
    /// @param paymentToken Address of payment token
    function processPayment(
        PaymentConfig memory config,
        address seller,
        address buyer,
        uint256 amount,
        address paymentToken
    ) internal {
        uint256 fees = (amount * config.baseFee) / config.percentageBase;
        uint256 netValue = amount - fees;
        _processTokenPayment(paymentToken, buyer, seller, config.feeCollector, netValue, fees);
        emit PaymentProcessed(seller, buyer, amount, fees, paymentToken);
    }
    
    
    /// @notice Processes ERC20 token payments
    /// @dev Internal function to handle token transfers with fee deduction
    /// @param paymentToken Address of the ERC20 token
    /// @param buyer Address sending the payment
    /// @param seller Address receiving the net payment
    /// @param feeCollector Address receiving the fees
    /// @param netValue Amount to send to seller (after fees)
    /// @param fees Fee amount to send to collector
    function _processTokenPayment(
        address paymentToken,
        address buyer,
        address seller,
        address feeCollector,
        uint256 netValue,
        uint256 fees
    ) private {
        IERC20 token = IERC20(paymentToken);
        token.safeTransferFrom(buyer, seller, netValue);  
        token.safeTransferFrom(buyer, feeCollector, fees);

    }
    
}