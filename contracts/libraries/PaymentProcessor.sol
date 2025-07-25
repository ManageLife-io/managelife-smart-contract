// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PaymentProcessor - Centralized payment processing library
/// @notice Handles both ETH and ERC20 token payments with fee calculation
/// @dev Library to consolidate payment logic across contracts
library PaymentProcessor {
    
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
    /// @dev Handles both ETH and ERC20 token payments with proper fee calculation
    /// @param config Payment configuration containing fee settings
    /// @param seller Address of the payment recipient
    /// @param buyer Address of the payment sender
    /// @param amount Total payment amount
    /// @param paymentToken Address of payment token (address(0) for ETH)
    function processPayment(
        PaymentConfig memory config,
        address seller,
        address buyer,
        uint256 amount,
        address paymentToken
    ) internal {
        uint256 fees = (amount * config.baseFee) / config.percentageBase;
        uint256 netValue = amount - fees;

        if (paymentToken == address(0)) {
            _processETHPayment(seller, config.feeCollector, netValue, fees, buyer, amount);
        } else {
            _processTokenPayment(paymentToken, buyer, seller, config.feeCollector, netValue, fees);
        }

        emit PaymentProcessed(seller, buyer, amount, fees, paymentToken);
    }
    
    /// @notice Processes ETH payments
    /// @dev Internal function to handle ETH transfers with fee deduction from msg.value
    /// @param seller Address to receive the net payment
    /// @param feeCollector Address to receive the fees
    /// @param netValue Amount to send to seller (after fees)
    /// @param fees Fee amount to send to collector
    /// @param buyer Address of the buyer (for refunds)
    /// @param totalAmount Total amount expected
    function _processETHPayment(
        address seller,
        address feeCollector,
        uint256 netValue,
        uint256 fees,
        address buyer,
        uint256 totalAmount
    ) private {
        require(msg.value >= totalAmount, "Insufficient ETH sent");

        // Send payment to seller
        (bool successSeller, ) = payable(seller).call{value: netValue}("");
        require(successSeller, "Payment to seller failed");

        // Send fee to collector
        (bool successFee, ) = payable(feeCollector).call{value: fees}("");
        require(successFee, "Fee payment failed");

        // Handle excess ETH refund with improved gas handling
        uint256 excess = msg.value - totalAmount;
        if (excess > 0) {
            // Use higher gas limit to accommodate modern contracts
            // Increased from 2300 to 10000 gas to handle modern contracts
            (bool successRefund, ) = payable(buyer).call{value: excess, gas: 10000}("");
            require(successRefund, "Refund failed - consider using pull pattern");
        }
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
        
        // Transfer from buyer to seller
        require(
            token.transferFrom(buyer, seller, netValue),
            "Transfer to seller failed"
        );
        
        // Transfer fee from buyer to fee collector
        require(
            token.transferFrom(buyer, feeCollector, fees),
            "Fee transfer failed"
        );
    }
    
    /// @notice Validates payment parameters
    /// @dev Checks if payment amount and token are valid
    /// @param listedPrice Expected payment amount
    /// @param offerPrice Offered payment amount
    /// @param paymentToken Token address for payment
    /// @param allowedTokens Mapping of allowed payment tokens
    /// @param whitelistEnabled Whether token whitelist is enabled
    /// @return bool True if payment is valid
    function validatePayment(
        uint256 listedPrice,
        uint256 offerPrice,
        address paymentToken,
        mapping(address => bool) storage allowedTokens,
        bool whitelistEnabled
    ) internal view returns (bool) {
        // Validate that the payment token is allowed
        if (whitelistEnabled && !allowedTokens[paymentToken]) {
            return false;
        }
        
        if (paymentToken == address(0)) {
            return msg.value >= listedPrice && offerPrice == listedPrice;
        } else {
            return offerPrice == listedPrice;
        }
    }
}