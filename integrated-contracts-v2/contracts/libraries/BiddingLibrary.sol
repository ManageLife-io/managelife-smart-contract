// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ErrorCodes} from "./ErrorCodes.sol";

/**
 * @title BiddingLibrary
 * @notice Library for managing property bidding logic
 * @dev Extracted from PropertyMarket to reduce contract size
 */
library BiddingLibrary {
    using SafeERC20 for IERC20;

    // Optimized Bid structure with packed fields
    struct Bid {
        uint256 tokenId;
        address bidder;
        uint256 amount;
        address paymentToken;
        uint64 bidTimestamp;  // Packed: sufficient until year 2554
        bool isActive;
    }

    event BidPlaced(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount,
        address paymentToken
    );

    event BidCancelled(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount
    );

    /**
     * @notice Get the highest active bid for a token
     * @param bids Array of bids for the token
     * @return highest The highest bid amount
     */
    function getHighestActiveBid(Bid[] storage bids) internal view returns (uint256 highest) {
        uint256 length = bids.length;
        for (uint256 i = 0; i < length; i++) {
            if (bids[i].isActive && bids[i].amount > highest) {
                highest = bids[i].amount;
            }
        }
    }

    /**
     * @notice Cancel all active bids for a token
     * @param bids Array of bids for the token
     * @param bidIndexByBidder Mapping of bidder to bid index
     * @param tokenId The token ID
     */
    function cancelAllBids(
        Bid[] storage bids,
        mapping(address => mapping(uint256 => uint256)) storage bidIndexByBidder,
        uint256 tokenId,
        mapping(address => mapping(address => uint256)) storage refundableBalances
    ) internal {
        uint256 length = bids.length;
        for (uint256 i = 0; i < length; i++) {
            if (bids[i].isActive) {
                address bidder = bids[i].bidder;
                uint256 refundAmount = bids[i].amount;
                address paymentToken = bids[i].paymentToken;

                bids[i].isActive = false;
                bidIndexByBidder[bidder][tokenId] = 0;
                
                refundableBalances[bidder][paymentToken] += refundAmount;
                emit BidCancelled(tokenId, bidder, refundAmount);
            }
        }
    }

    /**
     * @notice Cancel all bids except for a specific bidder
     * @param bids Array of bids for the token
     * @param bidIndexByBidder Mapping of bidder to bid index
     * @param tokenId The token ID
     * @param excludeBidder The bidder to exclude from cancellation
     */
    function cancelOtherBids(
        Bid[] storage bids,
        mapping(address => mapping(uint256 => uint256)) storage bidIndexByBidder,
        uint256 tokenId,
        address excludeBidder,
        mapping(address => mapping(address => uint256)) storage refundableBalances
    ) internal {
        uint256 length = bids.length;
        for (uint256 i = 0; i < length; i++) {
            if (bids[i].isActive && bids[i].bidder != excludeBidder) {
                address bidder = bids[i].bidder;
                uint256 refundAmount = bids[i].amount;
                address paymentToken = bids[i].paymentToken;

                bids[i].isActive = false;
                bidIndexByBidder[bidder][tokenId] = 0;
                
                refundableBalances[bidder][paymentToken] += refundAmount;
                emit BidCancelled(tokenId, bidder, refundAmount);
            }
        }
    }

    /**
     * @notice Validate a new bid amount
     * @param bids Array of bids for the token
     * @param bidAmount The new bid amount
     * @param listingPrice The listing price
     * @return isValid Whether the bid is valid
     */
    function validateBidAmount(
        Bid[] storage bids,
        uint256 bidAmount,
        uint256 listingPrice
    ) internal view returns (bool isValid) {
        require(bidAmount >= listingPrice, ErrorCodes.E206);
        
        uint256 highestBid = getHighestActiveBid(bids);
        if (highestBid > 0) {
            require(bidAmount >= highestBid, ErrorCodes.E205);
        }
        
        return true;
    }

    /**
     * @notice Process a bid placement or update
     * @param bids Array of bids for the token
     * @param bidIndexByBidder Mapping of bidder to bid index
     * @param tokenId The token ID
     * @param bidder The bidder address
     * @param bidAmount The bid amount
     * @param paymentToken The payment token address
     * @param listingPrice The listing price
     */
    function placeBid(
        Bid[] storage bids,
        mapping(address => mapping(uint256 => uint256)) storage bidIndexByBidder,
        uint256 tokenId,
        address bidder,
        uint256 bidAmount,
        address paymentToken,
        uint256 listingPrice
    ) internal {
        // Validate bid amount
        validateBidAmount(bids, bidAmount, listingPrice);

        uint256 existingBidIndex = bidIndexByBidder[bidder][tokenId];
        
        if (existingBidIndex > 0) {
            // Update existing bid
            Bid storage existingBid = bids[existingBidIndex - 1];
            require(existingBid.isActive, ErrorCodes.E202);
            require(existingBid.paymentToken == paymentToken, ErrorCodes.E302);
            require(bidAmount > existingBid.amount, ErrorCodes.E205);

            uint256 additionalAmount = bidAmount - existingBid.amount;
            IERC20(paymentToken).safeTransferFrom(bidder, address(this), additionalAmount);

            existingBid.amount = bidAmount;
            existingBid.bidTimestamp = uint64(block.timestamp);
        } else {
            // Create new bid
            IERC20(paymentToken).safeTransferFrom(bidder, address(this), bidAmount);

            Bid memory newBid = Bid({
                tokenId: tokenId,
                bidder: bidder,
                amount: bidAmount,
                paymentToken: paymentToken,
                bidTimestamp: uint64(block.timestamp),
                isActive: true
            });

            bids.push(newBid);
            bidIndexByBidder[bidder][tokenId] = bids.length;
        }

        emit BidPlaced(tokenId, bidder, bidAmount, paymentToken);
    }

    /**
     * @notice Cancel a specific bid
     * @param bids Array of bids for the token
     * @param bidIndexByBidder Mapping of bidder to bid index
     * @param tokenId The token ID
     * @param bidder The bidder address
     */
    function cancelBid(
        Bid[] storage bids,
        mapping(address => mapping(uint256 => uint256)) storage bidIndexByBidder,
        uint256 tokenId,
        address bidder,
        mapping(address => mapping(address => uint256)) storage refundableBalances
    ) internal {
        uint256 bidIndex = bidIndexByBidder[bidder][tokenId];
        require(bidIndex > 0, ErrorCodes.E201);

        Bid storage bid = bids[bidIndex - 1];
        require(bid.isActive, ErrorCodes.E202);
        require(bid.bidder == bidder, ErrorCodes.E203);

        uint256 refundAmount = bid.amount;
        address paymentToken = bid.paymentToken;

        bid.isActive = false;
        bidIndexByBidder[bidder][tokenId] = 0;

        refundableBalances[bidder][paymentToken] += refundAmount;
        emit BidCancelled(tokenId, bidder, refundAmount);
    }
}

