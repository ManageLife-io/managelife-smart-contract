// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../governance/AdminControl.sol";

contract PropertyMarket is ReentrancyGuard, AdminControl {
    constructor(address _nftiAddress, address _nftmAddress, address initialAdmin, address feeCollector, address rewardsVault) AdminControl(initialAdmin, feeCollector, rewardsVault) {
        require(_nftiAddress != address(0), "Invalid NFTi contract address");
        require(_nftmAddress != address(0), "Invalid NFTm contract address");
        
        allowedPaymentTokens[address(0)] = true;
        nftiContract = IERC721(_nftiAddress);
        nftmContract = IERC721(_nftmAddress);
    }

    uint256 public constant MIN_BID_INCREMENT_PERCENT = 5;
    uint256 public constant BID_PERCENTAGE_MULTIPLIER = 100;
    
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

    IERC721 public immutable nftiContract;
    IERC721 public immutable nftmContract;
    
    mapping(address => bool) public allowedPaymentTokens;
    bool public whitelistEnabled = true;
    
    mapping(uint256 => PropertyListing) public listings;
    mapping(address => mapping(uint256 => uint256)) public leaseTerms;
    
    mapping(uint256 => Bid[]) public bidsForToken;
    mapping(uint256 => mapping(address => uint256)) public ethBidDeposits;
    mapping(address => mapping(uint256 => uint256)) public bidIndexByBidder;
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
    
    // Token whitelist events
    event PaymentTokenAdded(address indexed token, address indexed operator);
    event PaymentTokenRemoved(address indexed token, address indexed operator);
    event WhitelistStatusChanged(bool enabled, address indexed operator);

    // ========== Constructor ==========
    // Constructor moved to the top of the contract
    
    // ========== Token Whitelist Management ==========
    
    /// @notice Checks if a token is allowed for payment
    /// @dev Returns true for ETH (address 0) if it's in the whitelist
    /// @param token The token address to check
    /// @return bool True if the token is allowed for payment
    function isTokenAllowed(address token) public view returns (bool) {
        if (!whitelistEnabled) return true;
        return allowedPaymentTokens[token];
    }
    
    /// @notice Adds a token to the allowed payment tokens list
    /// @dev Only callable by operators
    /// @param token The token address to add
    function addAllowedToken(address token) external onlyOperator {
        require(token != address(0), "ETH is allowed by default");
        allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token, msg.sender);
    }
    
    /// @notice Removes a token from the allowed payment tokens list
    /// @dev Only callable by operators
    /// @param token The token address to remove
    function removeAllowedToken(address token) external onlyOperator {
        require(token != address(0), "Cannot remove ETH as payment method");
        allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token, msg.sender);
    }
    
    /// @notice Enables or disables the token whitelist functionality
    /// @dev Only callable by operators
    /// @param enabled Whether the whitelist should be enabled
    function setWhitelistEnabled(bool enabled) external onlyOperator {
        whitelistEnabled = enabled;
        emit WhitelistStatusChanged(enabled, msg.sender);
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
            this.isKYCVerified(msg.sender),
            "KYC required"
        );
        
        require(price > 0, "Invalid price");
        
        require(
            isTokenAllowed(paymentToken),
            "Payment token not allowed"
        );

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
            this.isKYCVerified(msg.sender),
            "KYC required"
        );
        
        require(
            _validatePayment(listing.price, offerPrice, listing.paymentToken),
            "Payment failed"
        );

        // First update state variables (Effects)
        listing.status = PropertyStatus.SOLD;
        
        // Cancel all active bids on direct purchase
        _cancelAllBids(tokenId);
        
        // Then process payment and external calls (Interactions)
        _processPayment(
            listing.seller,
            listing.price,
            listing.paymentToken
        );

        nftiContract.safeTransferFrom(
            listing.seller,
            msg.sender,
            tokenId,
            ""
        );
        
        emit PropertySold(
            tokenId,
            msg.sender,
            listing.price,
            listing.paymentToken
        );
    }

    function _cancelAllBids(uint256 tokenId) private {
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive) {
                bids[i].isActive = false;
                bidIndexByBidder[bids[i].bidder][tokenId] = 0;
                emit BidCancelled(tokenId, bids[i].bidder, bids[i].amount);
            }
        }
    }

    // ========== Payment Processing Functions ==========
    function _validatePayment(
        uint256 listedPrice,
        uint256 offerPrice,
        address paymentToken
    ) private view returns (bool) {
        // Validate that the payment token is allowed
        if (!isTokenAllowed(paymentToken)) {
            return false;
        }
        
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
        uint256 baseFee = feeConfig.baseFee;
        address feeCollector = feeConfig.feeCollector;
        uint256 fees = (price * baseFee) / PERCENTAGE_BASE;
        uint256 netValue = price - fees;

        if (paymentToken == address(0)) {
            // Checks
            require(msg.value >= price, "Insufficient ETH");
            
            // Calculate refund amount if any
            uint256 refundAmount = msg.value > price ? msg.value - price : 0;
            
            // Effects - No state changes needed here as this is a payment processing function
            // The calling function should handle state changes before calling this function
            
            // Interactions - External calls at the end
            // First handle the refund if needed
            if (refundAmount > 0) {
                (bool refundSuccess, ) = payable(msg.sender).call{value: refundAmount}("");
                require(refundSuccess, "ETH refund failed");
            }
            
            // Then transfer to seller
            (bool successSeller, ) = payable(seller).call{value: netValue}("");
            require(successSeller, "Seller transfer failed");
            
            // Finally transfer fees
            (bool successFee, ) = payable(feeCollector).call{value: fees}("");
            require(successFee, "Fee transfer failed");
        } else {
            // Checks and Interactions for ERC20 tokens
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

        require(newPrice > 0, "Invalid price");
        require(isTokenAllowed(newPaymentToken), "Payment token not allowed");
        
        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
    }

    // ========== Access Modifiers ==========
    modifier onlyOperator() {
        bytes32 role = OPERATOR_ROLE;
        require(
            hasRole(role, msg.sender),
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
    
    // ========== Bidding Constants ==========
    /// @notice Minimum percentage increment required for new bids
    
    /**
     * @dev Buyer places a bid on an NFT
     * @param tokenId NFT identifier
     * @param bidAmount Bid amount
     * @param paymentToken Payment token address (address(0) for ETH)
     */
    /// @notice Places a bid on a listed property
    /// @dev Requires KYC verification and proper token approval
    /// @param tokenId The ID of the NFT to bid on
    /// @param bidAmount The amount to bid
    /// @param paymentToken The token address for payment (address(0) for ETH)
    
    function placeBid(uint256 tokenId, uint256 bidAmount, address paymentToken) external payable nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Property not listed");
        require(listing.seller != msg.sender, "Cannot bid on your own listing");
        require(bidAmount > 0, "Bid amount must be greater than 0");
        require(this.isKYCVerified(msg.sender), "KYC required");
        require(isTokenAllowed(paymentToken), "Payment token not allowed");
        
        // Check if bid exists and update if it does
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];
        
        // Handle token approval
        // Validate payment method
        if (paymentToken == address(0)) {
            require(msg.value == bidAmount, "ETH amount mismatch");
            
            // Handle ETH deposits properly for existing vs new bids
            if (existingBidIndex > 0) {
                // For existing bids, refund previous deposit and set new one
                uint256 previousDeposit = ethBidDeposits[tokenId][msg.sender];
                ethBidDeposits[tokenId][msg.sender] = msg.value;
                if (previousDeposit > 0) {
                    (bool success, ) = payable(msg.sender).call{value: previousDeposit}("");
                    require(success, "ETH refund failed");
                }
            } else {
                // For new bids, simply set the deposit
                ethBidDeposits[tokenId][msg.sender] = msg.value;
            }
        } else {
            IERC20 token = IERC20(paymentToken);
            uint256 allowance = token.allowance(msg.sender, address(this));
            require(allowance >= bidAmount, "Insufficient token allowance");
        }
        
        require(bidAmount >= listing.price, "Bid must meet listing price");
        
        // Find highest active bid
        uint256 highestBid = 0;
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highestBid) {
                highestBid = bids[i].amount;
            }
        }
        
        if (highestBid > 0) {
            uint256 minBid = highestBid * (BID_PERCENTAGE_MULTIPLIER + MIN_BID_INCREMENT_PERCENT) / BID_PERCENTAGE_MULTIPLIER;
            require(bidAmount >= minBid, "Bid must be 5% higher than current highest");
        }
        
        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            require(existingBid.isActive, "Bid is not active");
            require(existingBid.paymentToken == paymentToken, "Cannot change payment token");
            uint256 minIncrement = existingBid.amount * (BID_PERCENTAGE_MULTIPLIER + MIN_BID_INCREMENT_PERCENT) / BID_PERCENTAGE_MULTIPLIER;
            require(bidAmount >= minIncrement, "Bid must be 5% higher than previous");
            existingBid.amount = bidAmount;
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
     * @dev Seller accepts a specific bid on an NFT
     * @param tokenId NFT identifier
     * @param bidIndex Index of the bid to accept
     * @param expectedBidder Expected buyer address
     * @param expectedAmount Expected bid amount
     * @param expectedPaymentToken Expected payment token address
     */
    /// @notice Accepts a specific bid on a listed property
    /// @dev Transfers NFT to bidder and handles payment to seller
    /// @param tokenId The ID of the NFT
    /// @param bidIndex The index of the bid to accept
    /// @param expectedBidder The address of the bidder whose bid to accept
    /// @param expectedAmount The expected bid amount
    /// @param expectedPaymentToken The expected payment token address
    function acceptBid(uint256 tokenId, uint256 bidIndex, address expectedBidder, uint256 expectedAmount, address expectedPaymentToken) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Property not listed");
        require(listing.seller == msg.sender, "Not the seller");
        
        require(bidIndex > 0, "Invalid bid index");
        require(bidsForToken[tokenId].length >= bidIndex, "Invalid bid index");
        
        Bid storage acceptedBid = bidsForToken[tokenId][bidIndex - 1];
        require(acceptedBid.isActive, "Bid is not active");
        require(acceptedBid.bidder == expectedBidder, "Bidder mismatch");
        require(acceptedBid.amount == expectedAmount, "Amount mismatch");
        require(acceptedBid.paymentToken == expectedPaymentToken, "Token mismatch");
        
        // Verify NFT ownership
        require(nftiContract.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        
        // First update state variables (Effects)
        listing.status = PropertyStatus.SOLD;
        acceptedBid.isActive = false;
        
        // Calculate payment details
        uint256 baseFee = feeConfig.baseFee;
        address feeCollector = feeConfig.feeCollector;
        uint256 fees = (acceptedBid.amount * baseFee) / PERCENTAGE_BASE;
        uint256 netValue = acceptedBid.amount - fees;
        
        // Then process payment and external calls (Interactions)
        if (acceptedBid.paymentToken == address(0)) {
            // ETH payment - requires buyer to send ETH
            // ETH transfer not handled here as we use pre-authorization model
            uint256 ethBalance = ethBidDeposits[tokenId][acceptedBid.bidder];
            require(ethBalance >= acceptedBid.amount, "Insufficient ETH escrow");
            
            // Update state before external calls
            ethBidDeposits[tokenId][acceptedBid.bidder] = 0;
            
            // Make external calls using .call instead of .transfer for better gas handling
            (bool successSeller, ) = payable(msg.sender).call{value: netValue}("");
            require(successSeller, "Seller transfer failed");
            
            (bool successFee, ) = payable(feeCollector).call{value: fees}("");
            require(successFee, "Fee transfer failed");
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
        
        // Transfer NFT (last external interaction)
        nftiContract.safeTransferFrom(msg.sender, acceptedBid.bidder, tokenId, "");
        
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
     * @dev Buyer cancels their bid
     * @param tokenId NFT identifier
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

        // Refund ETH if applicable
        if (bid.paymentToken == address(0)) {
            uint256 ethAmount = ethBidDeposits[tokenId][msg.sender];
            require(ethAmount >= bid.amount, "Insufficient ETH escrow");
            ethBidDeposits[tokenId][msg.sender] = 0;
            (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
            require(success, "Bid refund failed");
        }
        
        emit BidCancelled(tokenId, msg.sender, bid.amount);
    }
    
    /**
     * @dev Get all active bids for a specific NFT
     * @param tokenId NFT identifier
     * @return Array of active bids
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
     * @dev Get bid from a specific buyer for a specific NFT
     * @param tokenId NFT identifier
     * @param bidder Buyer address
     * @return Bid information, returns default value if it doesn't exist
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
     * @dev Clear all bids for an NFT except for the specified one
     * @param tokenId NFT identifier
     * @param exceptIndex Index of the bid to keep
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
