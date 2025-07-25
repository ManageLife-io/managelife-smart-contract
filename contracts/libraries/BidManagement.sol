// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./ErrorCodes.sol";

/// @title BidManagement - Library for bid-related operations
/// @dev Extracts bid management logic to reduce main contract size
library BidManagement {
    
    struct Bid {
        uint256 tokenId;
        address bidder;
        uint256 amount;
        address paymentToken;
        uint256 bidTimestamp;
        bool isActive;
    }

    /// @notice Find the highest active bid for a token
    /// @param bids Array of bids for the token
    /// @return highest The highest bid amount
    function getHighestActiveBid(Bid[] storage bids) external view returns (uint256 highest) {
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highest) {
                highest = bids[i].amount;
            }
        }
    }

    /// @notice Cancel all bids for a token
    /// @param bids Array of bids for the token
    /// @param bidIndexByBidder Mapping to track bidder indices
    /// @param tokenId The token ID
    function cancelAllBids(
        Bid[] storage bids,
        mapping(address => mapping(uint256 => uint256)) storage bidIndexByBidder,
        uint256 tokenId
    ) external {
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive) {
                bids[i].isActive = false;
                bidIndexByBidder[bids[i].bidder][tokenId] = 0;
            }
        }
    }

    /// @notice Cancel all bids except for a specific bidder
    /// @param bids Array of bids for the token
    /// @param bidIndexByBidder Mapping to track bidder indices
    /// @param tokenId The token ID
    /// @param excludeBidder Bidder to exclude from cancellation
    function cancelOtherBids(
        Bid[] storage bids,
        mapping(address => mapping(uint256 => uint256)) storage bidIndexByBidder,
        uint256 tokenId,
        address excludeBidder
    ) external {
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].bidder != excludeBidder) {
                bids[i].isActive = false;
                bidIndexByBidder[bids[i].bidder][tokenId] = 0;
            }
        }
    }

    /// @notice Validate bid amount against listing price and existing bids
    /// @param bidAmount The proposed bid amount
    /// @param listingPrice The listing price
    /// @param highestBid The current highest bid
    /// @return valid Whether the bid amount is valid
    function validateBidAmount(
        uint256 bidAmount,
        uint256 listingPrice,
        uint256 highestBid
    ) external pure returns (bool valid) {
        // Must meet listing price
        if (bidAmount < listingPrice) return false;
        
        // Must meet or exceed highest bid if exists
        if (highestBid > 0 && bidAmount < highestBid) return false;
        
        return true;
    }

    /// @notice Calculate minimum increment for a bid
    /// @param currentPrice The current highest price
    /// @return increment The minimum increment required
    function calculateMinimumIncrement(uint256 currentPrice) external pure returns (uint256 increment) {
        if (currentPrice < 1 ether) {
            return currentPrice * 5 / 100; // 5% for small amounts
        } else if (currentPrice < 10 ether) {
            return currentPrice * 3 / 100; // 3% for medium amounts
        } else {
            return currentPrice * 1 / 100; // 1% for large amounts
        }
    }

    /// @notice Clean up inactive bids in batches
    /// @param bids Array of bids for the token
    /// @param bidIndexByBidder Mapping to track bidder indices
    /// @param tokenId The token ID
    /// @param batchSize Maximum number of bids to process
    /// @return removedCount Number of inactive bids removed
    function cleanupInactiveBids(
        Bid[] storage bids,
        mapping(address => mapping(uint256 => uint256)) storage bidIndexByBidder,
        uint256 tokenId,
        uint256 batchSize
    ) external returns (uint256 removedCount) {
        uint256 originalLength = bids.length;
        if (originalLength == 0) return 0;

        uint256 processLimit = originalLength > batchSize ? batchSize : originalLength;

        for (uint256 i = 0; i < processLimit; i++) {
            if (!bids[i].isActive) {
                bidIndexByBidder[bids[i].bidder][tokenId] = 0;
                removedCount++;
            }
        }

        // Only rebuild if we processed all bids and there were removals
        if (processLimit == originalLength && removedCount > 0) {
            _rebuildBidsArray(bids);
        }
    }

    /// @notice Rebuild bids array by removing inactive entries
    /// @param bids Array of bids to rebuild
    function _rebuildBidsArray(Bid[] storage bids) internal {
        uint256 activeCount = 0;
        uint256 length = bids.length;
        
        // Count active bids
        for (uint256 i = 0; i < length; i++) {
            if (bids[i].isActive) {
                activeCount++;
            }
        }

        // Create new array with only active bids
        Bid[] memory activeBids = new Bid[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < length; i++) {
            if (bids[i].isActive) {
                activeBids[index] = bids[i];
                index++;
            }
        }

        // Clear the storage array and repopulate
        while (bids.length > 0) {
            bids.pop();
        }
        
        for (uint256 i = 0; i < activeCount; i++) {
            bids.push(activeBids[i]);
        }
    }

    /// @notice Find active ETH bid for payment completion
    /// @param bids Array of bids for the token
    /// @return bidIndex Index of the ETH bid (0 if not found)
    /// @return bidder Address of the bidder
    /// @return bidAmount Amount of the bid
    function findActiveETHBid(Bid[] storage bids) 
        external 
        view 
        returns (uint256 bidIndex, address bidder, uint256 bidAmount) 
    {
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].paymentToken == address(0)) {
                return (i, bids[i].bidder, bids[i].amount);
            }
        }
        return (0, address(0), 0);
    }
}
