// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./ErrorCodes.sol";

/// @title MarketValidation - Common validation functions for PropertyMarket
/// @dev Library to reduce code duplication and contract size
library MarketValidation {
    
    /// @notice Validates basic requirements for market operations
    /// @param user Address to validate
    /// @param amount Amount to validate
    /// @param isKYCRequired Whether KYC is required
    /// @param userKYCStatus User's KYC status
    /// @param isPaused Whether the contract is paused
    function validateBasicRequirements(
        address user,
        uint256 amount,
        bool isKYCRequired,
        bool userKYCStatus,
        bool isPaused
    ) internal pure {
        require(user != address(0), ErrorCodes.E001);
        require(amount > 0, ErrorCodes.E003);
        if (isKYCRequired) {
            require(userKYCStatus, ErrorCodes.E403);
        }
        require(!isPaused, ErrorCodes.E404);
    }
    
    /// @notice Validates NFT ownership
    /// @param nftContract The NFT contract
    /// @param tokenId Token ID to check
    /// @param expectedOwner Expected owner address
    function validateNFTOwnership(
        address nftContract,
        uint256 tokenId,
        address expectedOwner
    ) internal view {
        require(
            IERC721(nftContract).ownerOf(tokenId) == expectedOwner,
            ErrorCodes.E105
        );
    }
    
    /// @notice Validates payment token
    /// @param paymentToken Token address (address(0) for ETH)
    /// @param allowedTokens Mapping of allowed tokens
    function validatePaymentToken(
        address paymentToken,
        mapping(address => bool) storage allowedTokens
    ) internal view {
        require(allowedTokens[paymentToken], ErrorCodes.E301);
    }
    
    /// @notice Validates ETH payment
    /// @param sentValue msg.value
    /// @param requiredAmount Required amount
    function validateETHPayment(
        uint256 sentValue,
        uint256 requiredAmount
    ) internal pure {
        require(sentValue == requiredAmount, ErrorCodes.E207);
    }
    
    /// @notice Validates ERC20 allowance
    /// @param token Token contract
    /// @param owner Token owner
    /// @param spender Token spender
    /// @param amount Required amount
    function validateERC20Allowance(
        address token,
        address owner,
        address spender,
        uint256 amount
    ) internal view {
        require(
            IERC20(token).allowance(owner, spender) >= amount,
            ErrorCodes.E208
        );
    }
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
}
