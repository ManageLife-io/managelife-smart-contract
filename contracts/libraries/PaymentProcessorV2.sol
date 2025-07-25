// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title PaymentProcessorV2 - Enhanced payment processing with pull refunds
/// @notice Handles both ETH and ERC20 token payments with improved gas handling
/// @dev Contract to consolidate payment logic with pull pattern for failed refunds
contract PaymentProcessorV2 is ReentrancyGuard {
    
    /// @notice Mapping to track pending refunds for users
    mapping(address => uint256) public pendingRefunds;
    
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
    
    /// @notice Emitted when a refund is stored for manual withdrawal
    event RefundStored(address indexed user, uint256 amount);
    
    /// @notice Emitted when a user withdraws their pending refund
    event RefundWithdrawn(address indexed user, uint256 amount);
    
    /// @notice Processes ETH payment with improved refund handling
    /// @dev Internal function to handle ETH transfers with fee deduction
    /// @param config Payment configuration
    /// @param seller Address receiving the net payment
    /// @param buyer Address sending the payment
    /// @param netValue Amount to send to seller (after fees)
    /// @param fees Fee amount to send to collector
    function processETHPayment(
        PaymentConfig memory config,
        address payable seller,
        address buyer,
        uint256 netValue,
        uint256 fees
    ) external payable nonReentrant {
        uint256 totalAmount = netValue + fees;
        require(msg.value >= totalAmount, "Insufficient payment");
        
        // Send net amount to seller
        (bool successSeller, ) = seller.call{value: netValue}("");
        require(successSeller, "Payment to seller failed");
        
        // Send fee to collector
        (bool successFee, ) = payable(config.feeCollector).call{value: fees}("");
        require(successFee, "Fee payment failed");

        // Handle excess ETH refund with improved gas handling
        uint256 excess = msg.value - totalAmount;
        if (excess > 0) {
            // Use higher gas limit to accommodate modern contracts
            // If refund fails, store for manual withdrawal (pull pattern)
            (bool successRefund, ) = payable(buyer).call{value: excess, gas: 10000}("");
            if (!successRefund) {
                // Store failed refund for manual withdrawal
                pendingRefunds[buyer] += excess;
                emit RefundStored(buyer, excess);
            }
        }
        
        emit PaymentProcessed(seller, buyer, netValue, fees, address(0));
    }
    
    /// @notice Allows users to withdraw their pending refunds
    /// @dev Pull pattern for failed refunds to prevent gas griefing
    function withdrawPendingRefund() external nonReentrant {
        uint256 refundAmount = pendingRefunds[msg.sender];
        require(refundAmount > 0, "No pending refund");
        
        pendingRefunds[msg.sender] = 0;
        
        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        require(success, "Refund withdrawal failed");
        
        emit RefundWithdrawn(msg.sender, refundAmount);
    }
    
    /// @notice Processes ERC20 token payments
    /// @dev Internal function to handle token transfers with fee deduction
    /// @param paymentToken Address of the ERC20 token
    /// @param buyer Address sending the payment
    /// @param seller Address receiving the net payment
    /// @param feeCollector Address receiving the fees
    /// @param netValue Amount to send to seller (after fees)
    /// @param fees Fee amount to send to collector
    function processTokenPayment(
        address paymentToken,
        address buyer,
        address seller,
        address feeCollector,
        uint256 netValue,
        uint256 fees
    ) external nonReentrant {
        IERC20 token = IERC20(paymentToken);
        uint256 totalAmount = netValue + fees;
        
        // Transfer total amount from buyer to this contract
        require(token.transferFrom(buyer, address(this), totalAmount), "Token transfer failed");
        
        // Transfer net amount to seller
        require(token.transfer(seller, netValue), "Payment to seller failed");
        
        // Transfer fees to collector
        require(token.transfer(feeCollector, fees), "Fee payment failed");
        
        emit PaymentProcessed(seller, buyer, netValue, fees, paymentToken);
    }
    
    /// @notice Calculates fees based on configuration
    /// @param amount The base amount
    /// @param config Payment configuration
    /// @return fees The calculated fee amount
    function calculateFees(uint256 amount, PaymentConfig memory config) external pure returns (uint256 fees) {
        return (amount * config.baseFee) / config.percentageBase;
    }
    
    /// @notice Gets pending refund amount for a user
    /// @param user The user address
    /// @return amount The pending refund amount
    function getPendingRefund(address user) external view returns (uint256 amount) {
        return pendingRefunds[user];
    }
}
