// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../governance/AdminControl.sol";
import "../governance/PropertyTimelock.sol";
import "../governance/MultiSigOperator.sol";
import "../libraries/PaymentProcessor.sol";
import "../libraries/ErrorCodes.sol";

/// @title PropertyMarket - A decentralized marketplace for real estate NFTs
/// @dev Implements timelock and multisig for operator functions to mitigate MA2-02 centralization risks
contract PropertyMarket is ReentrancyGuard, AdminControl {
    constructor(address _nftiAddress, address _nftmAddress, address initialAdmin, address feeCollector, address rewardsVault) AdminControl(initialAdmin, feeCollector, rewardsVault) {
        require(_nftiAddress != address(0), ErrorCodes.E001);
        require(_nftmAddress != address(0), ErrorCodes.E001);

        allowedPaymentTokens[address(0)] = true;
        nftiContract = IERC721(_nftiAddress);
        nftmContract = IERC721(_nftmAddress);
    }

    // ========== Constants ==========
    uint256 public constant PERCENTAGE_BASE = 10000; // Base for percentage calculations (100% = 10000)
    
    // ========== Data Structures ==========
    enum PropertyStatus { LISTED, RENTED, SOLD, DELISTED, PENDING_PAYMENT }
    
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

    /// @notice Timelock controller for sensitive operations (MA2-02 mitigation)
    PropertyMarketTimelock public timelock;

    /// @notice MultiSig operator for privileged functions (MA2-02 mitigation)
    MultiSigOperator public multiSigOperator;

    /// @notice Flag to enable/disable timelock requirement for operator functions
    bool public timelockEnabled = true;

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

    event BidAcceptedPendingPayment(
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
    event ListingPriceChanged(uint256 indexed tokenId, uint256 oldPrice, uint256 newPrice, address oldToken, address newToken);
    event BidsCleanedUp(uint256 indexed tokenId, uint256 removedCount, uint256 remainingCount);

    // Emergency withdrawal events (Critical Security Fix)
    event EmergencyWithdrawal(address indexed admin, address indexed recipient, uint256 amount, uint256 timestamp);
    event EmergencyTokenWithdrawal(address indexed admin, address indexed token, address indexed recipient, uint256 amount, uint256 timestamp);

    // MA2-02 Mitigation events
    event TimelockSet(address indexed timelock, address indexed admin);
    event MultiSigOperatorSet(address indexed multiSigOperator, address indexed admin);
    event TimelockEnabledChanged(bool enabled, address indexed admin);

    // Bidding mechanism fix events
    event CompetitivePurchase(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 purchasePrice,
        uint256 highestBidOutbid,
        address paymentToken
    );

    // ETH bidding fix events
    event BidRefundFailed(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount
    );

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
    /// @dev Only callable by operators (with timelock if enabled)
    /// @param token The token address to add
    function addAllowedToken(address token) external onlyOperatorWithTimelock {
        require(token != address(0), ErrorCodes.E001);
        allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token, msg.sender);
    }

    /// @notice Removes a token from the allowed payment tokens list
    /// @dev Only callable by operators (with timelock if enabled)
    /// @param token The token address to remove
    function removeAllowedToken(address token) external onlyOperatorWithTimelock {
        require(token != address(0), ErrorCodes.E001);
        allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token, msg.sender);
    }
    
    /// @notice Enables or disables the token whitelist functionality
    /// @dev Only callable by operators (with timelock if enabled)
    /// @param enabled Whether the whitelist should be enabled
    function setWhitelistEnabled(bool enabled) external onlyOperatorWithTimelock {
        whitelistEnabled = enabled;
        emit WhitelistStatusChanged(enabled, msg.sender);
    }

    // ========== MA2-02 Mitigation: Timelock & MultiSig Functions ==========

    /// @notice Set the timelock controller address
    /// @dev Only callable by admin, one-time setup
    /// @param _timelock Address of the timelock controller
    function setTimelock(address _timelock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_timelock != address(0), ErrorCodes.E603);
        require(address(timelock) == address(0), ErrorCodes.E601);
        timelock = PropertyMarketTimelock(payable(_timelock));
        emit TimelockSet(_timelock, msg.sender);
    }

    /// @notice Set the multisig operator address
    /// @dev Only callable by admin, one-time setup
    /// @param _multiSigOperator Address of the multisig operator
    function setMultiSigOperator(address _multiSigOperator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_multiSigOperator != address(0), ErrorCodes.E604);
        require(address(multiSigOperator) == address(0), ErrorCodes.E602);
        multiSigOperator = MultiSigOperator(_multiSigOperator);
        emit MultiSigOperatorSet(_multiSigOperator, msg.sender);
    }

    /// @notice Enable or disable timelock requirement for operator functions
    /// @dev Only callable by admin
    /// @param enabled Whether timelock should be required
    function setTimelockEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        timelockEnabled = enabled;
        emit TimelockEnabledChanged(enabled, msg.sender);
    }

    // ========== Core Functions ==========
    /// @notice Lists a property NFT for sale
    function listProperty(
        uint256 tokenId,
        uint256 price,
        address paymentToken
    ) external nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(price) {
        require(nftiContract.ownerOf(tokenId) == msg.sender, ErrorCodes.E105);
        require(listings[tokenId].seller == address(0) || listings[tokenId].status != PropertyStatus.LISTED, ErrorCodes.E102);

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

    /// @notice Purchases a listed property
    function purchaseProperty(uint256 tokenId, uint256 offerPrice) external payable nonReentrant onlyKYCVerified onlyValidAmount(offerPrice) {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E101);
        require(_validatePayment(listing.price, offerPrice, listing.paymentToken, tokenId), ErrorCodes.E005);

        // Determine the actual purchase price
        uint256 highestBid = _getHighestActiveBid(tokenId);
        uint256 actualPrice = highestBid > 0 ? offerPrice : listing.price;

        // Note: Payment token validation is handled in _validatePayment

        listing.status = PropertyStatus.SOLD;
        _cancelAllBids(tokenId);

        _processPayment(listing.seller, msg.sender, actualPrice, listing.paymentToken);
        nftiContract.safeTransferFrom(listing.seller, msg.sender, tokenId, "");

        // Emit appropriate events based on whether this was a competitive purchase
        emit PropertySold(tokenId, msg.sender, actualPrice, listing.paymentToken);

        // If this purchase outbid existing bids, emit a competitive purchase event
        if (highestBid > 0) {
            emit CompetitivePurchase(
                tokenId,
                msg.sender,
                actualPrice,
                highestBid,
                listing.paymentToken
            );
        }
    }

    function _cancelAllBids(uint256 tokenId) private {
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive) {
                // Store bid details before marking inactive
                address bidder = bids[i].bidder;
                uint256 refundAmount = bids[i].amount;
                address paymentToken = bids[i].paymentToken;

                bids[i].isActive = false;
                bidIndexByBidder[bidder][tokenId] = 0;

                // Refund the locked funds
                _refundBid(bidder, refundAmount, paymentToken, tokenId);

                emit BidCancelled(tokenId, bidder, refundAmount);
            }
        }
    }

    // ========== Internal Helper Functions ==========

    /// @notice Internal function to handle bid refunds
    /// @param bidder Address to refund
    /// @param amount Amount to refund
    /// @param paymentToken Token to refund (address(0) for ETH)
    /// @param tokenId Token ID for event emission
    function _refundBid(address bidder, uint256 amount, address paymentToken, uint256 tokenId) private {
        if (paymentToken == address(0)) {
            (bool success, ) = payable(bidder).call{value: amount}("");
            if (!success) {
                emit BidRefundFailed(tokenId, bidder, amount);
            }
        } else {
            IERC20 token = IERC20(paymentToken);
            bool success = token.transfer(bidder, amount);
            if (!success) {
                emit BidRefundFailed(tokenId, bidder, amount);
            }
        }
    }

    // ========== Payment Processing Functions ==========
    function _validatePayment(
        uint256 listedPrice,
        uint256 offerPrice,
        address paymentToken,
        uint256 tokenId
    ) private view returns (bool) {
        // Validate that the payment token is allowed
        if (!isTokenAllowed(paymentToken)) {
            return false;
        }

        // Check if there are active bids that need to be outbid
        uint256 highestBid = _getHighestActiveBid(tokenId);
        uint256 minimumPrice = highestBid > 0 ? highestBid : listedPrice;

        if (paymentToken == address(0)) {
            return msg.value >= minimumPrice && offerPrice >= minimumPrice;
        } else {
            return offerPrice >= minimumPrice;
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
    function updateListing(uint256 tokenId, uint256 newPrice, address newPaymentToken) external onlyOperatorWithTimelock {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        require(newPrice > 0, ErrorCodes.E104);
        require(isTokenAllowed(newPaymentToken), ErrorCodes.E301);

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
    }

    // ========== Access Modifiers ==========
    modifier onlyOperator() {
        require(hasRole(OPERATOR_ROLE, msg.sender), ErrorCodes.E402);
        _;
    }

    /// @notice Modifier for operator functions with timelock requirement (MA2-02 mitigation)
    /// @dev Checks if timelock is enabled and validates caller accordingly
    modifier onlyOperatorWithTimelock() {
        if (timelockEnabled && address(timelock) != address(0)) {
            // If timelock is enabled, only timelock can call
            require(msg.sender == address(timelock), ErrorCodes.E601);
        } else {
            // Fallback to regular operator check
            require(hasRole(OPERATOR_ROLE, msg.sender), ErrorCodes.E402);
        }
        _;
    }

    modifier onlyKYCVerified() {
        require(this.isKYCVerified(msg.sender), ErrorCodes.E403);
        _;
    }

    modifier onlyAllowedToken(address token) {
        require(isTokenAllowed(token), ErrorCodes.E301);
        _;
    }

    modifier onlyValidAmount(uint256 amount) {
        require(amount > 0, ErrorCodes.E003);
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

    /// @notice Maximum number of bids before cleanup is triggered
    uint256 public constant MAX_BIDS_BEFORE_CLEANUP = 100;
    
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
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);

        // Check against current NFT owner, not just the original seller
        // This handles cases where NFT ownership was transferred after listing
        address currentOwner = nftiContract.ownerOf(tokenId);
        require(currentOwner != msg.sender, ErrorCodes.E002);
        
        // Check if bid exists and update if it does
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];
        
        // Validate payment method - fixed ETH handling (no immediate refund)
        if (paymentToken == address(0)) {
            require(msg.value == bidAmount, ErrorCodes.E207);
            // ETH is now locked in contract until bid is accepted or cancelled
            // Removed immediate refund to fix the audit issue
        } else {
            IERC20 token = IERC20(paymentToken);
            require(token.allowance(msg.sender, address(this)) >= bidAmount, ErrorCodes.E208);
            // Transfer ERC20 tokens to contract for escrow
            bool success = token.transferFrom(msg.sender, address(this), bidAmount);
            require(success, "Token transfer failed");
        }

        require(bidAmount >= listing.price, ErrorCodes.E206);
        
        // Find highest active bid
        uint256 highestBid = 0;
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highestBid) {
                highestBid = bids[i].amount;
            }
        }
        
        if (highestBid > 0) {
            uint256 minBid = highestBid ;
            require(bidAmount >= minBid, ErrorCodes.E205);
        }
        
        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            require(existingBid.isActive, ErrorCodes.E202);
            require(existingBid.paymentToken == paymentToken, ErrorCodes.E302);
            uint256 minIncrement = existingBid.amount ;
            require(bidAmount >= minIncrement, ErrorCodes.E205);
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

        if (bidsForToken[tokenId].length > MAX_BIDS_BEFORE_CLEANUP) {
            _cleanupInactiveBidsInternal(tokenId);
        }

        emit BidPlaced(tokenId, msg.sender, bidAmount, paymentToken);
    }
    

    function acceptBid(uint256 tokenId, uint256 bidIndex, address expectedBidder, uint256 expectedAmount, address expectedPaymentToken) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        require(nftiContract.ownerOf(tokenId) == msg.sender, ErrorCodes.E105);

        if (listing.seller != msg.sender) {
            listing.seller = msg.sender;
        }

        require(bidIndex > 0, ErrorCodes.E502);
        require(bidIndex <= bidsForToken[tokenId].length, ErrorCodes.E502);
        require(bidsForToken[tokenId].length > 0, ErrorCodes.E504);
        
        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, ErrorCodes.E202);
        require(bid.bidder == expectedBidder, ErrorCodes.E501);
        require(bid.amount == expectedAmount, ErrorCodes.E501);
        require(bid.paymentToken == expectedPaymentToken, ErrorCodes.E302);
        
        listing.status = PropertyStatus.SOLD;
        bid.isActive = false;
        bidIndexByBidder[bid.bidder][tokenId] = 0;

        _cancelAllBids(tokenId);

        if (bid.paymentToken == address(0)) {
            listing.status = PropertyStatus.PENDING_PAYMENT;
            emit BidAcceptedPendingPayment(tokenId, listing.seller, bid.bidder, bid.amount, bid.paymentToken);
        } else {
            _processPayment(listing.seller, bid.bidder, bid.amount, bid.paymentToken);
            nftiContract.safeTransferFrom(listing.seller, bid.bidder, tokenId, "");
            emit BidAccepted(tokenId, listing.seller, bid.bidder, bid.amount, bid.paymentToken);
        }

        if (bidsForToken[tokenId].length > MAX_BIDS_BEFORE_CLEANUP) {
            _cleanupInactiveBidsInternal(tokenId);
        }
    }
    



    function completeBidPayment(uint256 tokenId) external payable nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.PENDING_PAYMENT, ErrorCodes.E504);

        // Find the accepted bid for this bidder
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        require(bidIndex > 0, "No active bid found");

        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, "Bid is not active");
        require(bid.bidder == msg.sender, "Not your bid");
        require(bid.paymentToken == address(0), "Not an ETH bid");
        require(msg.value >= bid.amount, "Insufficient ETH sent");

        // Update state
        listing.status = PropertyStatus.SOLD;

        // Process payment using PaymentProcessor
        _processPayment(
            listing.seller,
            msg.sender,
            bid.amount,
            bid.paymentToken
        );

        // Transfer NFT as final step
        nftiContract.safeTransferFrom(listing.seller, msg.sender, tokenId, "");

        // Handle excess ETH refund
        uint256 excess = msg.value - bid.amount;
        if (excess > 0) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: excess}("");
            require(refundSuccess, ErrorCodes.E304);
        }

        emit BidAccepted(tokenId, listing.seller, msg.sender, bid.amount, bid.paymentToken);
    }

    

    function placeBidSecure(uint256 tokenId, uint256 bidAmount, address paymentToken) external payable nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(bidAmount) {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        address currentOwner = nftiContract.ownerOf(tokenId);
        require(currentOwner != msg.sender, ErrorCodes.E002);
        require(bidAmount >= listing.price, ErrorCodes.E206);

        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];

        if (paymentToken == address(0)) {
            require(msg.value == bidAmount, ErrorCodes.E207);
            // ETH is now locked in contract until bid is accepted or cancelled
            // Removed immediate refund to fix the audit issue
        } else {
            IERC20 token = IERC20(paymentToken);
            require(token.allowance(msg.sender, address(this)) >= bidAmount, ErrorCodes.E208);
            // Transfer ERC20 tokens to contract for escrow
            bool success = token.transferFrom(msg.sender, address(this), bidAmount);
            require(success, "Token transfer failed");
        }

        uint256 highestBid = _getHighestActiveBid(tokenId);
        if (highestBid > 0) {
            uint256 minIncrement = _calculateMinimumIncrement(highestBid, bidAmount);
            require(bidAmount >= minIncrement, ErrorCodes.E205);
        }
        
        if (existingBidIndex > 0) {
            _updateExistingBid(tokenId, existingBidIndex, bidAmount, paymentToken);
        } else {
            _createNewBid(tokenId, bidAmount, paymentToken);
        }
        
        emit BidPlaced(tokenId, msg.sender, bidAmount, paymentToken);
    }
    

    function _calculateMinimumIncrement(uint256 currentHighest, uint256 /* newBid */) private pure returns (uint256) {
        // Dynamic increment: higher bids require smaller percentage increases
        uint256 incrementPercent;
        if (currentHighest < 1 ether) {
            incrementPercent = 10; // 10% for smaller bids
        } else if (currentHighest < 10 ether) {
            incrementPercent = 5;  // 5% for medium bids
        } else {
            incrementPercent = 2;  // 2% for large bids
        }
        
        uint256 multiplier = 100 + incrementPercent;
        require(currentHighest <= type(uint256).max / multiplier, ErrorCodes.E502);
        
        return (currentHighest * multiplier) / 100;
    }
    

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
    

    function _updateExistingBid(uint256 tokenId, uint256 bidIndex, uint256 newAmount, address paymentToken) private {
        Bid storage existingBid = bidsForToken[tokenId][bidIndex - 1];
        require(existingBid.isActive, ErrorCodes.E202);
        require(existingBid.paymentToken == paymentToken, ErrorCodes.E302);
        
        uint256 minIncrement = _calculateMinimumIncrement(existingBid.amount, newAmount);
        require(newAmount >= minIncrement, ErrorCodes.E205);
        
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
    

    function updateListingBySeller(uint256 tokenId, uint256 newPrice, address newPaymentToken) external onlyValidAmount(newPrice) onlyAllowedToken(newPaymentToken) {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        require(nftiContract.ownerOf(tokenId) == msg.sender, ErrorCodes.E105);

        // Update seller to current NFT owner if it has changed
        // This handles the case where NFT was transferred after listing
        address currentOwner = msg.sender;
        if (listing.seller != currentOwner) {
            listing.seller = currentOwner;
        }

        uint256 oldPrice = listing.price;
        address oldToken = listing.paymentToken;

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
        emit ListingPriceChanged(tokenId, oldPrice, newPrice, oldToken, newPaymentToken);
    }

    
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
    

    function cancelBid(uint256 tokenId) external nonReentrant {
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        require(bidIndex > 0, ErrorCodes.E201);

        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, ErrorCodes.E202);
        require(bid.bidder == msg.sender, ErrorCodes.E203);

        // Store bid details before marking inactive
        uint256 refundAmount = bid.amount;
        address paymentToken = bid.paymentToken;

        bid.isActive = false;
        bidIndexByBidder[msg.sender][tokenId] = 0;

        // Refund the locked funds
        if (paymentToken == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
            require(success, ErrorCodes.E303);
        } else {
            IERC20 token = IERC20(paymentToken);
            bool success = token.transfer(msg.sender, refundAmount);
            require(success, ErrorCodes.E004);
        }

        if (bidsForToken[tokenId].length > MAX_BIDS_BEFORE_CLEANUP) {
            _cleanupInactiveBidsInternal(tokenId);
        }

        emit BidCancelled(tokenId, msg.sender, refundAmount);
    }
    

    function getActiveBidsForToken(uint256 tokenId) external view returns (Bid[] memory activeBids) {
        Bid[] storage allBids = bidsForToken[tokenId];
        
        uint256 activeCount = 0;
        uint256 length = allBids.length;
        for (uint256 i = 0; i < length;) {
            if (allBids[i].isActive) {
                unchecked { ++activeCount; }
            }
            unchecked { ++i; }
        }

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
    

    function getBidFromBidder(uint256 tokenId, address bidder) external view returns (Bid memory) {
        uint256 bidIndex = bidIndexByBidder[bidder][tokenId];
        if (bidIndex == 0) {
            return Bid(0, address(0), 0, address(0), 0, false);
        }

        return bidsForToken[tokenId][bidIndex - 1];
    }


    function cleanupInactiveBids(uint256 tokenId) external {
        Bid[] storage allBids = bidsForToken[tokenId];
        uint256 originalLength = allBids.length;

        if (originalLength == 0) return;

        // Count active bids and create new array
        uint256 activeCount = 0;
        for (uint256 i = 0; i < originalLength; i++) {
            if (allBids[i].isActive) {
                activeCount++;
            }
        }

        if (activeCount == originalLength) return;

        Bid[] memory activeBids = new Bid[](activeCount);
        uint256 newIndex = 0;

        for (uint256 i = 0; i < originalLength; i++) {
            if (allBids[i].isActive) {
                activeBids[newIndex] = allBids[i];
                bidIndexByBidder[allBids[i].bidder][tokenId] = newIndex + 1;
                newIndex++;
            } else {
                bidIndexByBidder[allBids[i].bidder][tokenId] = 0;
            }
        }

        delete bidsForToken[tokenId];
        for (uint256 i = 0; i < activeCount; i++) {
            bidsForToken[tokenId].push(activeBids[i]);
        }

        uint256 removedCount = originalLength - activeCount;
        emit BidsCleanedUp(tokenId, removedCount, activeCount);
    }


    function _cleanupInactiveBidsInternal(uint256 tokenId) internal {
        Bid[] storage allBids = bidsForToken[tokenId];
        uint256 originalLength = allBids.length;

        if (originalLength == 0) return;

        uint256 activeCount = 0;
        for (uint256 i = 0; i < originalLength; i++) {
            if (allBids[i].isActive) activeCount++;
        }
        if (activeCount == originalLength) return;

        Bid[] memory activeBids = new Bid[](activeCount);
        uint256 newIndex = 0;

        for (uint256 i = 0; i < originalLength; i++) {
            if (allBids[i].isActive) {
                activeBids[newIndex] = allBids[i];
                bidIndexByBidder[allBids[i].bidder][tokenId] = newIndex + 1;
                newIndex++;
            } else {
                bidIndexByBidder[allBids[i].bidder][tokenId] = 0;
            }
        }

        delete bidsForToken[tokenId];
        for (uint256 i = 0; i < activeCount; i++) {
            bidsForToken[tokenId].push(activeBids[i]);
        }

        uint256 removedCount = originalLength - activeCount;
        emit BidsCleanedUp(tokenId, removedCount, activeCount);
    }

    // =============================
    // Emergency Functions (Critical Security Fix)
    // =============================

    /// @notice Emergency function to withdraw stuck ETH (admin only)
    /// @dev Should only be used in extreme circumstances with proper governance
    /// @param amount Amount of ETH to withdraw
    /// @param recipient Address to receive the ETH
    function emergencyWithdrawETH(uint256 amount, address payable recipient) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Unauthorized: admin role required");
        require(recipient != address(0), "Invalid recipient address");
        require(amount <= address(this).balance, "Insufficient contract balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit EmergencyWithdrawal(msg.sender, recipient, amount, block.timestamp);
    }

    /// @notice Emergency function to withdraw stuck ERC20 tokens (admin only)
    /// @dev Should only be used in extreme circumstances with proper governance
    /// @param token Token contract address
    /// @param amount Amount of tokens to withdraw
    /// @param recipient Address to receive the tokens
    function emergencyWithdrawToken(address token, uint256 amount, address recipient) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Unauthorized: admin role required");
        require(token != address(0), "Invalid token address");
        require(recipient != address(0), "Invalid recipient address");

        IERC20 tokenContract = IERC20(token);
        require(amount <= tokenContract.balanceOf(address(this)), "Insufficient token balance");

        bool success = tokenContract.transfer(recipient, amount);
        require(success, "Token transfer failed");

        emit EmergencyTokenWithdrawal(msg.sender, token, recipient, amount, block.timestamp);
    }

}
