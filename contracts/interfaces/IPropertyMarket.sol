// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IPropertyMarket {
    // Listing functions
    function listProperty(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 confirmationPeriod
    ) external;
    
    function unlistProperty(uint256 tokenId) external;
    
    // Purchase functions
    function purchasePropertyAtListingPrice(uint256 tokenId) external;
    function confirmPurchase(uint256 tokenId) external;
    function rejectPurchase(uint256 tokenId) external;
    function cancelExpiredPurchase(uint256 tokenId) external;
    
    // Bidding functions
    function placeBid(uint256 tokenId, uint256 bidAmount) external;
    function withdrawBid(uint256 tokenId) external;
    function changeBiddingActiveStatus(uint256 tokenId, bool biddingActive) external;
    function acceptBid(
        uint256 tokenId,
        uint256 topBidIndex,
        address expectedBidder,
        uint256 expectedAmount
    ) external;
    
    // Admin functions
    function addAllowedToken(address token) external;
    function removeAllowedToken(address token) external;
    function updateListingByAdmin(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    ) external;
    function emergencyWithdrawToken(
        address token,
        uint256 amount,
        address recipient
    ) external;
    
    // Seller functions
    function updateListingBySeller(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    ) external;
    
    // View functions
    function getListingDetails(uint256 tokenId) external view returns (
        address, // seller
        uint256, // price
        address, // paymentToken
        uint8,   // status (PropertyStatus enum as uint8)
        uint256, // listTimestamp
        uint256, // confirmationPeriod
        bool,    // biddingActive
        address, // highestBidder
        uint256  // highestBid
    );
    
    // Add the TopBidCandidate struct (needed for the next function)
    struct TopBidCandidate {
        address bidder;
        uint256 amount;
        uint256 bidTimestamp;
    }
    //ALERT: if TOP_BIDS_COUNT changes in the contract, this will need to be updated.
    function getTopBidsForListing(uint256 tokenId) external view returns (
        TopBidCandidate[10] memory // topBids array
    );
    
    // Public variables (automatically generate getters)
    function allowedPaymentTokens(address token) external view returns (bool);
    function listings(uint256 tokenId) external view returns (
        uint256, // tokenId
        address, // seller
        uint256, // price
        address, // paymentToken
        uint8,   // status
        uint256, // listTimestamp
        uint256, // lastRenewed
        uint256, // confirmationPeriod
        bool,    // biddingActive
        address, // highestBidder
        uint256  // highestBid
    );
    function pendingPurchases(uint256 tokenId) external view returns (
        uint256, // tokenId
        address, // buyer
        uint256, // price
        address, // paymentToken
        uint256, // purchaseTimestamp
        uint256, // confirmationDeadline
        bool     // fundsDeposited
    );
}