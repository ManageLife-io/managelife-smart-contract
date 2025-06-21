// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../governance/AdminControl.sol";
import "../libraries/PaymentProcessor.sol";
import "../libraries/Errors.sol";
import "../libraries/Validation.sol";

/// @title PropertyMarket - A decentralized marketplace for real estate NFTs
/// @notice This contract enables listing, buying, selling and bidding on real estate NFTs
/// @dev Implements a secure marketplace with support for both direct purchases and bidding
/// @custom:security-contact security@example.com
contract PropertyMarket is ReentrancyGuard, AdminControl {
    constructor(address _nftiAddress, address _nftmAddress, address initialAdmin, address feeCollector, address rewardsVault) AdminControl(initialAdmin, feeCollector, rewardsVault) {
        Validation.validateNonZeroAddress(_nftiAddress);
        Validation.validateNonZeroAddress(_nftmAddress);
        
        // Add ETH as default allowed payment method
        allowedPaymentTokens[address(0)] = true;
        nftiContract = IERC721(_nftiAddress);
        nftmContract = IERC721(_nftmAddress);
    }

    // ========== Constants ==========
    uint256 public constant PERCENTAGE_BASE = 10000; // Base for percentage calculations (100% = 10000)
    
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
    IERC721 public immutable nftiContract;
    IERC721 public immutable nftmContract;
    
    // Token whitelist for payments
    mapping(address => bool) public allowedPaymentTokens;
    bool public whitelistEnabled = true; // Enable/disable whitelist functionality
    
    mapping(uint256 => PropertyListing) public listings;
    // Removed unused leaseTerms mapping
    
    // Bidding related mappings
    mapping(uint256 => Bid[]) public bidsForToken; // tokenId => all bids
    mapping(uint256 => mapping(address => uint256)) public ethBidDeposits; // tokenId => bidder => ETH amount
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
    ) external nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(price) {
        require(
            nftiContract.ownerOf(tokenId) == msg.sender,
            Errors.NOT_NFT_OWNER
        );

        require(
            listings[tokenId].status != PropertyStatus.LISTED,
            Errors.ALREADY_LISTED
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
    ) external payable nonReentrant onlyKYCVerified onlyValidAmount(offerPrice) {
        PropertyListing storage listing = listings[tokenId];
        
        require(
            listing.status == PropertyStatus.LISTED,
            Errors.NOT_AVAILABLE
        );
        
        require(
            _validatePayment(listing.price, offerPrice, listing.paymentToken),
            Errors.PAYMENT_FAILED
        );

        // First update state variables (Effects)
        listing.status = PropertyStatus.SOLD;
        
        // Cancel all active bids on direct purchase
        _cancelAllBids(tokenId);
        
        // Then process payment and external calls (Interactions)
        _processPayment(
            listing.seller,
            msg.sender,
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

    // ========== Internal Payment Processing ==========
    /// @notice Processes payment for property transactions
    /// @dev Handles both ETH and ERC20 token payments with proper fee calculation
    /// @param seller Address of the property seller
    /// @param buyer Address of the property buyer
    /// @param amount Total payment amount
    /// @param paymentToken Address of payment token (address(0) for ETH)
    function _processPayment(
        address seller,
        address buyer,
        uint256 amount,
        address paymentToken
    ) internal {
        PaymentProcessor.PaymentConfig memory config = PaymentProcessor.PaymentConfig({
            baseFee: feeConfig.baseFee,
            feeCollector: feeConfig.feeCollector,
            percentageBase: PERCENTAGE_BASE
        });
        
        PaymentProcessor.processPayment(
            config,
            seller,
            buyer,
            amount,
            paymentToken
        );
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
            Errors.NOT_LISTED
        );

        require(newPrice > 0, Errors.INVALID_PRICE);
        require(isTokenAllowed(newPaymentToken), Errors.TOKEN_NOT_ALLOWED);
        
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
            Errors.NOT_OPERATOR
        );
        _;
    }
    
    modifier onlyKYCVerified() {
        require(
            this.isKYCVerified(msg.sender),
            Errors.KYC_REQUIRED
        );
        _;
    }
    
    modifier onlyAllowedToken(address token) {
        require(
            isTokenAllowed(token),
            Errors.TOKEN_NOT_ALLOWED
        );
        _;
    }
    
    modifier onlyValidAmount(uint256 amount) {
        Validation.validatePositiveAmount(amount);
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
    uint256 public constant MIN_BID_INCREMENT_PERCENT = 5;
    
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
    
    function placeBid(uint256 tokenId, uint256 bidAmount, address paymentToken) external payable nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(bidAmount) {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, Errors.NOT_LISTED);
        require(listing.seller != msg.sender, Errors.CANNOT_BID_OWN_LISTING);
        
        // Check if bid exists and update if it does
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];
        
        // Handle token approval
        // Validate payment method
        if (paymentToken == address(0)) {
            require(msg.value == bidAmount, "ETH amount mismatch");
            ethBidDeposits[tokenId][msg.sender] += msg.value;
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
            uint256 minBid = highestBid * (100 + MIN_BID_INCREMENT_PERCENT) / 100;
            require(bidAmount >= minBid, "Bid must be 5% higher than current highest");
        }
        
        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            require(existingBid.isActive, "Bid is not active");
            require(existingBid.paymentToken == paymentToken, "Cannot change payment token");
            uint256 minIncrement = existingBid.amount * (100 + MIN_BID_INCREMENT_PERCENT) / 100;
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
        require(listing.seller == msg.sender, Errors.NOT_SELLER);
        
        // Verify real-time NFT ownership to prevent stale listing attacks
        require(nftiContract.ownerOf(tokenId) == msg.sender, Errors.NOT_NFT_OWNER);
        
        require(bidIndex > 0, Errors.INVALID_BID_INDEX);
        require(bidIndex <= bidsForToken[tokenId].length, Errors.INVALID_BID_INDEX);
        
        // Additional validation: ensure bid array is not empty
        require(bidsForToken[tokenId].length > 0, "No bids available");
        
        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, Errors.BID_NOT_ACTIVE);
        require(bid.bidder == expectedBidder, Errors.BIDDER_MISMATCH);
        require(bid.amount == expectedAmount, Errors.AMOUNT_MISMATCH);
        require(bid.paymentToken == expectedPaymentToken, Errors.PAYMENT_TOKEN_MISMATCH);
        
        // Update state first (Effects)
        listing.status = PropertyStatus.SOLD;
        bid.isActive = false;
        bidIndexByBidder[bid.bidder][tokenId] = 0;
        
        // Clear ETH deposit for this bidder
        uint256 ethAmount = ethBidDeposits[tokenId][bid.bidder];
        ethBidDeposits[tokenId][bid.bidder] = 0;
        
        // Cancel all other active bids
        _cancelAllBids(tokenId);
        
        // Process payment safely using PaymentProcessor (Interactions)
        if (bid.paymentToken == address(0)) {
            // ETH payment - validate deposit first
            require(ethAmount >= bid.amount, Errors.INSUFFICIENT_BALANCE);
            
            // Handle excess refund before payment processing with gas limit
            uint256 excess = ethAmount - bid.amount;
            if (excess > 0) {
                (bool successRefund, ) = payable(bid.bidder).call{value: excess, gas: 2300}("");
                require(successRefund, Errors.TRANSFER_FAILED);
            }
        }
        
        // Use PaymentProcessor for secure payment handling
        _processPayment(
            listing.seller,
            bid.bidder,
            bid.amount,
            bid.paymentToken
        );
        
        // Transfer NFT as final step (last external call)
        nftiContract.safeTransferFrom(listing.seller, bid.bidder, tokenId, "");
        
        emit BidAccepted(tokenId, listing.seller, bid.bidder, bid.amount, bid.paymentToken);
    }
    
    /**
     * @dev Emergency function to withdraw stuck ETH deposits
     * @param tokenId NFT identifier
     * @notice Only callable by the bidder who made the deposit
     */
    function emergencyWithdrawDeposit(uint256 tokenId) external nonReentrant {
        uint256 amount = ethBidDeposits[tokenId][msg.sender];
        require(amount > 0, Errors.INSUFFICIENT_BALANCE);
        
        // Check if there's an active bid that would prevent withdrawal
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        if (bidIndex > 0) {
            Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
            require(!bid.isActive, "Cannot withdraw with active bid");
        }
        
        // Clear deposit and transfer with gas limit
        ethBidDeposits[tokenId][msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: amount, gas: 2300}("");
        require(success, Errors.TRANSFER_FAILED);
        
        emit EmergencyWithdrawal(tokenId, msg.sender, amount);
    }
    
    // Add missing event
    event EmergencyWithdrawal(uint256 indexed tokenId, address indexed user, uint256 amount);
    
    /**
     * @dev Enhanced bid placement with better security checks
     */
    function placeBidSecure(uint256 tokenId, uint256 bidAmount, address paymentToken) external payable nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(bidAmount) {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, Errors.NOT_LISTED);
        require(listing.seller != msg.sender, Errors.CANNOT_BID_OWN_LISTING);
        
        // Enhanced minimum bid validation
        require(bidAmount >= listing.price, "Bid must meet listing price");
        
        // Check if bid exists and validate payment
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];
        
        if (paymentToken == address(0)) {
            require(msg.value == bidAmount, "ETH amount mismatch");
            ethBidDeposits[tokenId][msg.sender] += msg.value;
        } else {
            IERC20 token = IERC20(paymentToken);
            require(token.allowance(msg.sender, address(this)) >= bidAmount, "Insufficient token allowance");
        }
        
        // Enhanced bid increment validation with dynamic pricing
        uint256 highestBid = _getHighestActiveBid(tokenId);
        if (highestBid > 0) {
            uint256 minIncrement = _calculateMinimumIncrement(highestBid, bidAmount);
            require(bidAmount >= minIncrement, "Bid increment too low");
        }
        
        if (existingBidIndex > 0) {
            _updateExistingBid(tokenId, existingBidIndex, bidAmount, paymentToken);
        } else {
            _createNewBid(tokenId, bidAmount, paymentToken);
        }
        
        emit BidPlaced(tokenId, msg.sender, bidAmount, paymentToken);
    }
    
    /**
     * @dev Calculate minimum bid increment based on current highest bid
     * @dev Uses safe arithmetic to prevent integer overflow
     */
    function _calculateMinimumIncrement(uint256 currentHighest, uint256 newBid) private pure returns (uint256) {
        // Dynamic increment: higher bids require smaller percentage increases
        uint256 incrementPercent;
        if (currentHighest < 1 ether) {
            incrementPercent = 10; // 10% for smaller bids
        } else if (currentHighest < 10 ether) {
            incrementPercent = 5;  // 5% for medium bids
        } else {
            incrementPercent = 2;  // 2% for large bids
        }
        
        // Safe arithmetic to prevent overflow
        // Check for potential overflow before multiplication
        uint256 multiplier = 100 + incrementPercent;
        require(currentHighest <= type(uint256).max / multiplier, "Bid amount too large");
        
        return (currentHighest * multiplier) / 100;
    }
    
    /**
     * @dev Get highest active bid for a token
     */
    function _getHighestActiveBid(uint256 tokenId) private view returns (uint256) {
        uint256 highest = 0;
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highest) {
                highest = bids[i].amount;
            }
        }
        return highest;
    }
    
    /**
     * @dev Update existing bid with enhanced validation
     */
    function _updateExistingBid(uint256 tokenId, uint256 bidIndex, uint256 newAmount, address paymentToken) private {
        Bid storage existingBid = bidsForToken[tokenId][bidIndex - 1];
        require(existingBid.isActive, Errors.BID_NOT_ACTIVE);
        require(existingBid.paymentToken == paymentToken, "Cannot change payment token");
        
        uint256 minIncrement = _calculateMinimumIncrement(existingBid.amount, newAmount);
        require(newAmount >= minIncrement, "Bid increment too low");
        
        existingBid.amount = newAmount;
        existingBid.bidTimestamp = block.timestamp;
    }
    
    /**
     * @dev Create new bid with validation
     */
    function _createNewBid(uint256 tokenId, uint256 amount, address paymentToken) private {
        Bid memory newBid = Bid({
            tokenId: tokenId,
            bidder: msg.sender,
            amount: amount,
            paymentToken: paymentToken,
            bidTimestamp: block.timestamp,
            isActive: true
        });
        
        bidsForToken[tokenId].push(newBid);
        bidIndexByBidder[msg.sender][tokenId] = bidsForToken[tokenId].length;
    }
    
    /**
     * @dev Enhanced listing update with seller permission
     */
    function updateListingBySeller(uint256 tokenId, uint256 newPrice, address newPaymentToken) external onlyValidAmount(newPrice) onlyAllowedToken(newPaymentToken) {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, Errors.NOT_LISTED);
        require(listing.seller == msg.sender, Errors.NOT_SELLER);
        
        // Verify real-time NFT ownership
        require(nftiContract.ownerOf(tokenId) == msg.sender, Errors.NOT_NFT_OWNER);
        
        uint256 oldPrice = listing.price;
        address oldToken = listing.paymentToken;
        
        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;
        
        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
        emit ListingPriceChanged(tokenId, oldPrice, newPrice, oldToken, newPaymentToken);
    }
    
    // Add missing events
    event ListingPriceChanged(uint256 indexed tokenId, uint256 oldPrice, uint256 newPrice, address oldToken, address newToken);
    
    /**
     * @dev Get paginated active bids to prevent gas issues
     */
    function getActiveBidsForTokenPaginated(uint256 tokenId, uint256 offset, uint256 limit) external view returns (Bid[] memory activeBids, uint256 totalCount) {
        Bid[] storage allBids = bidsForToken[tokenId];
        
        // Count total active bids
        totalCount = 0;
        for (uint256 i = 0; i < allBids.length; i++) {
            if (allBids[i].isActive) {
                totalCount++;
            }
        }
        
        // Calculate actual limit
        uint256 actualLimit = limit;
        if (offset >= totalCount) {
            return (new Bid[](0), totalCount);
        }
        if (offset + limit > totalCount) {
            actualLimit = totalCount - offset;
        }
        
        // Create paginated result
        activeBids = new Bid[](actualLimit);
        uint256 activeIndex = 0;
        uint256 resultIndex = 0;
        
        for (uint256 i = 0; i < allBids.length && resultIndex < actualLimit; i++) {
            if (allBids[i].isActive) {
                if (activeIndex >= offset) {
                    activeBids[resultIndex] = allBids[i];
                    resultIndex++;
                }
                activeIndex++;
            }
        }
        
        return (activeBids, totalCount);

    }
    
    /**
     * @dev Bidder cancels their own bid
     * @param tokenId NFT identifier
     */
    /// @notice Cancels a bid placed by the caller
    /// @dev Refunds deposited ETH if applicable
    /// @param tokenId The ID of the NFT to cancel bid on
    function cancelBid(uint256 tokenId) external nonReentrant {
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        require(bidIndex > 0, Errors.NO_ACTIVE_BID);
        
        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, Errors.BID_NOT_ACTIVE);
        require(bid.bidder == msg.sender, Errors.NOT_YOUR_BID);
        
        // Update state first (Effects)
        bid.isActive = false;
        bidIndexByBidder[msg.sender][tokenId] = 0;
        
        // Handle ETH refund if applicable
        uint256 ethAmount = ethBidDeposits[tokenId][msg.sender];
        ethBidDeposits[tokenId][msg.sender] = 0;
        
        if (ethAmount > 0) {
            // Use safer call method for ETH transfer with gas limit
            (bool success, ) = payable(msg.sender).call{value: ethAmount, gas: 2300}("");
            require(success, Errors.TRANSFER_FAILED);
        }
        
        emit BidCancelled(tokenId, msg.sender, bid.amount);
    }
    
    /**
     * @dev Get all active bids for a token
     * @param tokenId NFT identifier
     * @return activeBids Array of active bids
     */
    /// @notice Retrieves all active bids for a specific token
    /// @dev Returns an array of active bids with bidder details
    /// @param tokenId The ID of the NFT
    /// @return activeBids Array of active bids
    function getActiveBidsForToken(uint256 tokenId) external view returns (Bid[] memory activeBids) {
        Bid[] storage allBids = bidsForToken[tokenId];
        
        // Count active bids first
        uint256 activeCount = 0;
        uint256 length = allBids.length;
        for (uint256 i = 0; i < length;) {
            if (allBids[i].isActive) {
                unchecked { ++activeCount; }
            }
            unchecked { ++i; }
        }
        
        // Create array of active bids
        activeBids = new Bid[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < length;) {
            if (allBids[i].isActive) {
                activeBids[index] = allBids[i];
                unchecked { ++index; }
            }
            unchecked { ++i; }
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
    
    // Removed unused _clearAllBidsExcept function
}
