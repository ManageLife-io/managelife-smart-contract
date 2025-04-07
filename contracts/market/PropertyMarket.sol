// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../governance/AdminControl.sol";

/// @title PropertyMarket - A decentralized marketplace for real estate NFTs
/// @notice This contract enables listing, buying, selling and bidding on real estate NFTs
/// @dev Implements a secure marketplace with support for both direct purchases and bidding
/// @custom:security-contact security@example.com
contract PropertyMarket is ReentrancyGuard {
    // ========== Data Structures ==========
    enum PropertyStatus { LISTED, RENTED, SOLD, DELISTED }    
    
    struct Bid {
        uint256 tokenId;
        address bidder;
        uint256 amount;
        address paymentToken;
        uint256 bidTimestamp;
        bool isActive;
    }
    
    struct PropertyListing {
        uint256 tokenId;
        address seller;
        uint256 price;
        address paymentToken;
        PropertyStatus status;
        uint256 listTimestamp;
        uint256 lastRenewed;
    }

    // ========== State Variables ==========
    AdminControl public immutable adminControl;
    IERC721 public immutable nftiContract;
    IERC721 public immutable nftmContract;
    
    mapping(uint256 => PropertyListing) public listings;
    mapping(address => mapping(uint256 => uint256)) public leaseTerms;
    
    // Bidding related mappings
    mapping(uint256 => Bid[]) public bidsForToken; // tokenId => all bids
    mapping(address => mapping(uint256 => uint256)) public bidIndexByBidder; // bidder => tokenId => bidIndex+1 (0 means no bid)

    // ========== Event Definitions ==========
    event NewListing(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        address paymentToken
    );
    
    event PropertySold(
        uint256 indexed tokenId,
        address buyer,
        uint256 price,
        address paymentToken
    );
    
    event ListingUpdated(
        uint256 indexed tokenId,
        uint256 newPrice,
        address newPaymentToken
    );
    
    // Bidding related events
    event BidPlaced(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount,
        address paymentToken
    );
    
    event BidAccepted(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed bidder,
        uint256 amount,
        address paymentToken
    );
    
    event BidCancelled(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount
    );

    // ========== Constructor ==========
    constructor(
        address _adminControl,
        address _nftiAddress,
        address _nftmAddress
    ) {
        adminControl = AdminControl(_adminControl);
        nftiContract = IERC721(_nftiAddress);
        nftmContract = IERC721(_nftmAddress);
    }

    // ========== Core Functions ==========
    /// @notice Lists a property NFT for sale in the marketplace
    /// @dev Requires the caller to be the NFT owner and KYC verified
    /// @param tokenId The ID of the NFT to list
    /// @param price The listing price
    /// @param paymentToken The token address for payment (address(0) for ETH)
    function listProperty(
        uint256 tokenId,
        uint256 price,
        address paymentToken
    ) external nonReentrant {
        require(
            nftiContract.ownerOf(tokenId) == msg.sender,
            "Not NFTi owner"
        );
        
        require(
            adminControl.isKYCVerified(msg.sender),
            "KYC required"
        );
        
        require(price > 0, "Invalid price");

        listings[tokenId] = PropertyListing({
            tokenId: tokenId,
            seller: msg.sender,
            price: price,
            paymentToken: paymentToken,
            status: PropertyStatus.LISTED,
            listTimestamp: block.timestamp,
            lastRenewed: block.timestamp
        });

        emit NewListing(tokenId, msg.sender, price, paymentToken);
    }

    /// @notice Purchases a listed property at the listed price
    /// @dev Handles both ETH and ERC20 payments with fee calculation
    /// @param tokenId The ID of the NFT to purchase
    /// @param offerPrice The amount offered for the property
    function purchaseProperty(
        uint256 tokenId,
        uint256 offerPrice
    ) external payable nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        
        require(
            listing.status == PropertyStatus.LISTED,
            "Not available"
        );
        
        require(
            adminControl.isKYCVerified(msg.sender),
            "KYC required"
        );
        
        require(
            _validatePayment(listing.price, offerPrice, listing.paymentToken),
            "Payment failed"
        );

        _processPayment(
            listing.seller,
            listing.price,
            listing.paymentToken
        );

        nftiContract.transferFrom(
            listing.seller,
            msg.sender,
            tokenId
        );
        listing.status = PropertyStatus.SOLD;
        
        emit PropertySold(
            tokenId,
            msg.sender,
            listing.price,
            listing.paymentToken
        );
    }

    // ========== Payment Processing Functions ==========
    function _validatePayment(
        uint256 listedPrice,
        uint256 offerPrice,
        address paymentToken
    ) private view returns (bool) {
        if (paymentToken == address(0)) {
            return msg.value >= listedPrice && offerPrice == listedPrice;
        } else {
            return offerPrice == listedPrice;
        }
    }

    function _processPayment(
        address seller,
        uint256 price,
        address paymentToken
    ) internal {
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig();
        uint256 fees = (price * baseFee) / 10000;
        uint256 netValue = price - fees;

        if (paymentToken == address(0)) {
            require(msg.value >= price, "Insufficient ETH");
            
            if (msg.value > price) {
                payable(msg.sender).transfer(msg.value - price);
            }
            
            payable(seller).transfer(netValue);
            payable(feeCollector).transfer(fees);
        } else {
            IERC20 token = IERC20(paymentToken);
            require(
                token.transferFrom(msg.sender, seller, netValue),
                "Transfer failed"
            );
            require(
                token.transferFrom(msg.sender, feeCollector, fees),
                "Fee transfer failed"
            );
        }
    }

    // ========== Management Functions ==========
    /// @notice Updates the price and payment token of a listed property
    /// @dev Only callable by operators
    /// @param tokenId The ID of the NFT to update
    /// @param newPrice The new listing price
    /// @param newPaymentToken The new payment token address
    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    ) external onlyOperator {
        PropertyListing storage listing = listings[tokenId];
        require(
            listing.status == PropertyStatus.LISTED,
            "Not active listing"
        );

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
    }

    // ========== Access Modifiers ==========
    modifier onlyOperator() {
        bytes32 role = adminControl.OPERATOR_ROLE();
        require(
            adminControl.hasRole(role, msg.sender),
            "Operator required"
        );
        _;
    }

    // ========== Helper Functions ==========
    /// @notice Retrieves the full details of a property listing
    /// @dev Returns all relevant information about a listed property
    /// @param tokenId The ID of the NFT
    /// @return seller The address of the seller
    /// @return price The current listing price
    /// @return paymentToken The accepted payment token address
    /// @return status The current status of the listing
    /// @return listTimestamp The timestamp when the property was listed
    function getListingDetails(uint256 tokenId)
        external
        view
        returns (
            address seller,
            uint256 price,
            address paymentToken,
            PropertyStatus status,
            uint256 listTimestamp
        )
    {
        PropertyListing storage listing = listings[tokenId];
        return (
            listing.seller,
            listing.price,
            listing.paymentToken,
            listing.status,
            listing.listTimestamp
        );
    }
    
    // ========== Bidding Functions ==========
    
    /**
     * @dev 买家对NFT进行出价
     * @param tokenId NFT的ID
     * @param bidAmount 出价金额
     * @param paymentToken 支付代币地址（0地址表示ETH）
     */
    /// @notice Places a bid on a listed property
    /// @dev Requires KYC verification and proper token approval
    /// @param tokenId The ID of the NFT to bid on
    /// @param bidAmount The amount to bid
    /// @param paymentToken The token address for payment (address(0) for ETH)
    function placeBid(uint256 tokenId, uint256 bidAmount, address paymentToken) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Property not listed");
        require(listing.seller != msg.sender, "Cannot bid on your own listing");
        require(bidAmount > 0, "Bid amount must be greater than 0");
        require(adminControl.isKYCVerified(msg.sender), "KYC required");
        
        // Check if bid exists and update if it does
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];
        
        // Handle token approval
        if (paymentToken != address(0)) {
            IERC20 token = IERC20(paymentToken);
            // Check allowance
            uint256 allowance = token.allowance(msg.sender, address(this));
            require(allowance >= bidAmount, "Insufficient token allowance");
        }
        
        if (existingBidIndex > 0) {
            // Update existing bid
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            require(existingBid.isActive, "Bid is not active");
            existingBid.amount = bidAmount;
            existingBid.paymentToken = paymentToken;
            existingBid.bidTimestamp = block.timestamp;
        } else {
            // Create new bid
            Bid memory newBid = Bid({
                tokenId: tokenId,
                bidder: msg.sender,
                amount: bidAmount,
                paymentToken: paymentToken,
                bidTimestamp: block.timestamp,
                isActive: true
            });
            
            bidsForToken[tokenId].push(newBid);
            bidIndexByBidder[msg.sender][tokenId] = bidsForToken[tokenId].length;
        }
        
        emit BidPlaced(tokenId, msg.sender, bidAmount, paymentToken);
    }
    
    /**
     * @dev 卖家接受特定买家的出价
     * @param tokenId NFT的ID
     * @param bidder 买家地址
     */
    /// @notice Accepts a specific bid on a listed property
    /// @dev Transfers NFT to bidder and handles payment to seller
    /// @param tokenId The ID of the NFT
    /// @param bidder The address of the bidder whose bid to accept
    function acceptBid(uint256 tokenId, address bidder) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Property not listed");
        require(listing.seller == msg.sender, "Not the seller");
        
        uint256 bidIndex = bidIndexByBidder[bidder][tokenId];
        require(bidIndex > 0, "No bid from this bidder");
        
        Bid storage acceptedBid = bidsForToken[tokenId][bidIndex - 1];
        require(acceptedBid.isActive, "Bid is not active");
        
        // Verify NFT ownership
        require(nftiContract.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        
        // Process payment
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig();
        uint256 fees = (acceptedBid.amount * baseFee) / 10000;
        uint256 netValue = acceptedBid.amount - fees;
        
        if (acceptedBid.paymentToken == address(0)) {
            // ETH payment - requires buyer to send ETH
            // ETH transfer not handled here as we use pre-authorization model
            revert("ETH bids not supported in this version");
        } else {
            // ERC20 token payment
            IERC20 token = IERC20(acceptedBid.paymentToken);
            
            // Transfer from buyer to seller
            require(
                token.transferFrom(acceptedBid.bidder, msg.sender, netValue),
                "Transfer to seller failed"
            );
            
            // Transfer fee from buyer to fee collector
            require(
                token.transferFrom(acceptedBid.bidder, feeCollector, fees),
                "Fee transfer failed"
            );
        }
        
        // Transfer NFT
        nftiContract.transferFrom(msg.sender, acceptedBid.bidder, tokenId);
        
        // Update status
        listing.status = PropertyStatus.SOLD;
        acceptedBid.isActive = false;
        
        // Clear all other bids for this NFT
        _clearAllBidsExcept(tokenId, bidIndex - 1);
        
        emit BidAccepted(
            tokenId,
            msg.sender,
            acceptedBid.bidder,
            acceptedBid.amount,
            acceptedBid.paymentToken
        );
    }
    
    /**
     * @dev 买家取消自己的出价
     * @param tokenId NFT的ID
     */
    /// @notice Cancels an active bid placed by the caller
    /// @dev Only the original bidder can cancel their bid
    /// @param tokenId The ID of the NFT the bid was placed on
    function cancelBid(uint256 tokenId) external nonReentrant {
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        require(bidIndex > 0, "No active bid");
        
        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, "Bid already inactive");
        require(bid.bidder == msg.sender, "Not the bidder");
        
        bid.isActive = false;
        bidIndexByBidder[msg.sender][tokenId] = 0;
        
        emit BidCancelled(tokenId, msg.sender, bid.amount);
    }
    
    /**
     * @dev 获取特定NFT的所有活跃出价
     * @param tokenId NFT的ID
     * @return 活跃出价数组
     */
    /// @notice Gets all active bids for a specific property
    /// @dev Returns an array of active bids, filtering out inactive ones
    /// @param tokenId The ID of the NFT
    /// @return An array of active Bid structs
    function getActiveBidsForToken(uint256 tokenId) external view returns (Bid[] memory) {
        Bid[] storage allBids = bidsForToken[tokenId];
        uint256 activeCount = 0;
        
        // Count active bids
        for (uint256 i = 0; i < allBids.length; i++) {
            if (allBids[i].isActive) {
                activeCount++;
            }
        }
        
        // Create result array
        Bid[] memory activeBids = new Bid[](activeCount);
        uint256 currentIndex = 0;
        
        // Fill result array
        for (uint256 i = 0; i < allBids.length; i++) {
            if (allBids[i].isActive) {
                activeBids[currentIndex] = allBids[i];
                currentIndex++;
            }
        }
        
        return activeBids;
    }
    
    /**
     * @dev 获取特定买家对特定NFT的出价
     * @param tokenId NFT的ID
     * @param bidder 买家地址
     * @return 出价信息，如果不存在则返回默认值
     */
    /// @notice Gets the current bid from a specific bidder
    /// @dev Returns a default empty bid if no active bid exists
    /// @param tokenId The ID of the NFT
    /// @param bidder The address of the bidder
    /// @return The Bid struct containing bid details
    function getBidFromBidder(uint256 tokenId, address bidder) external view returns (Bid memory) {
        uint256 bidIndex = bidIndexByBidder[bidder][tokenId];
        if (bidIndex == 0) {
            // Return empty bid
            return Bid(0, address(0), 0, address(0), 0, false);
        }
        
        return bidsForToken[tokenId][bidIndex - 1];
    }
    
    /**
     * @dev 清除NFT的所有出价，除了指定的一个
     * @param tokenId NFT的ID
     * @param exceptIndex 不清除的出价索引
     */
    function _clearAllBidsExcept(uint256 tokenId, uint256 exceptIndex) private {
        Bid[] storage bids = bidsForToken[tokenId];
        
        for (uint256 i = 0; i < bids.length; i++) {
            if (i != exceptIndex && bids[i].isActive) {
                bids[i].isActive = false;
                bidIndexByBidder[bids[i].bidder][tokenId] = 0;
            }
        }
    }
}
