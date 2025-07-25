// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ErrorCodes.sol";

/// @title PaymentValidation - Library for payment validation operations
/// @dev Extracts payment validation logic to reduce main contract size
library PaymentValidation {

    /// @notice Validate payment for property purchase
    /// @param listedPrice The original listing price
    /// @param offerPrice The offered price
    /// @param paymentToken The payment token address (address(0) for ETH)
    /// @param highestBid The current highest bid
    /// @param allowedTokens Mapping of allowed payment tokens
    /// @return valid Whether the payment is valid
    function validatePayment(
        uint256 listedPrice,
        uint256 offerPrice,
        address paymentToken,
        uint256 highestBid,
        mapping(address => bool) storage allowedTokens
    ) external view returns (bool valid) {
        // Validate that the payment token is allowed
        if (!allowedTokens[paymentToken]) {
            return false;
        }

        // Check if there are active bids that need to be outbid
        uint256 minimumPrice = highestBid > 0 ? highestBid : listedPrice;

        if (paymentToken == address(0)) {
            // For ETH payments, ensure msg.value equals offerPrice
            return msg.value >= minimumPrice && offerPrice >= minimumPrice && msg.value == offerPrice;
        } else {
            return offerPrice >= minimumPrice;
        }
    }

    /// @notice Validate token allowance for ERC20 payments
    /// @param token The ERC20 token contract
    /// @param spender The spender address (usually the contract)
    /// @param amount The required amount
    /// @return valid Whether allowance is sufficient
    function validateTokenAllowance(
        IERC20 token,
        address spender,
        uint256 amount
    ) external view returns (bool valid) {
        return token.allowance(msg.sender, spender) >= amount;
    }

    /// @notice Safe token transfer with deflationary token support
    /// @param token The ERC20 token contract
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @return actualReceived The actual amount received (may be less for deflationary tokens)
    function safeTokenTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) external returns (uint256 actualReceived) {
        uint256 balanceBefore = token.balanceOf(to);
        
        bool success = token.transferFrom(from, to, amount);
        require(success, ErrorCodes.E707);
        
        uint256 balanceAfter = token.balanceOf(to);
        actualReceived = balanceAfter - balanceBefore;
    }

    /// @notice Validate bid payment (ETH or ERC20)
    /// @param bidAmount The bid amount
    /// @param paymentToken The payment token (address(0) for ETH)
    /// @param allowedTokens Mapping of allowed payment tokens
    /// @return valid Whether the payment is valid
    function validateBidPayment(
        uint256 bidAmount,
        address paymentToken,
        mapping(address => bool) storage allowedTokens
    ) external view returns (bool valid) {
        // Check if token is allowed
        if (!allowedTokens[paymentToken]) {
            return false;
        }

        if (paymentToken == address(0)) {
            // For ETH, msg.value must equal bid amount
            return msg.value == bidAmount;
        } else {
            // For ERC20, check allowance
            IERC20 token = IERC20(paymentToken);
            return token.allowance(msg.sender, address(this)) >= bidAmount;
        }
    }

    /// @notice Calculate payment distribution (seller amount and fees)
    /// @param totalAmount The total payment amount
    /// @param feeRate The fee rate (in basis points)
    /// @param percentageBase The percentage base (usually 10000)
    /// @return sellerAmount Amount for the seller
    /// @return feeAmount Amount for fees
    function calculatePaymentDistribution(
        uint256 totalAmount,
        uint256 feeRate,
        uint256 percentageBase
    ) external pure returns (uint256 sellerAmount, uint256 feeAmount) {
        feeAmount = (totalAmount * feeRate) / percentageBase;
        sellerAmount = totalAmount - feeAmount;
    }

    /// @notice Validate ETH payment amount
    /// @param expectedAmount The expected ETH amount
    /// @return valid Whether msg.value matches expected amount
    function validateETHAmount(uint256 expectedAmount) external view returns (bool valid) {
        return msg.value == expectedAmount;
    }

    /// @notice Validate additional payment for bid increases
    /// @param oldAmount The previous bid amount
    /// @param newAmount The new bid amount
    /// @param paymentToken The payment token (address(0) for ETH)
    /// @return valid Whether the additional payment is valid
    /// @return additionalAmount The additional amount required
    function validateAdditionalPayment(
        uint256 oldAmount,
        uint256 newAmount,
        address paymentToken
    ) external view returns (bool valid, uint256 additionalAmount) {
        if (newAmount <= oldAmount) {
            return (msg.value == 0, 0);
        }

        additionalAmount = newAmount - oldAmount;

        if (paymentToken == address(0)) {
            return (msg.value == additionalAmount, additionalAmount);
        } else {
            IERC20 token = IERC20(paymentToken);
            return (token.allowance(msg.sender, address(this)) >= additionalAmount, additionalAmount);
        }
    }

    /// @notice Check if a token is deflationary
    /// @param token The token address
    /// @param deflationaryTokens Mapping of deflationary tokens
    /// @return isDeflationary Whether the token is deflationary
    function isDeflationaryToken(
        address token,
        mapping(address => bool) storage deflationaryTokens
    ) external view returns (bool isDeflationary) {
        return deflationaryTokens[token];
    }
}
