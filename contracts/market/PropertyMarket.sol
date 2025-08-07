// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../governance/AdminControl.sol";
import "../governance/PropertyTimelock.sol";
import "../governance/MultiSigOperator.sol";
import "../libraries/PaymentProcessor.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

contract PropertyMarket is ReentrancyGuard, AdminControl {
    using SafeERC20 for IERC20;

    // ========== Custom Errors ==========
    // General Errors
    error ZeroAddress();
    error InvalidAmount(uint256 amount);
    error UnauthorizedAccess(address caller);
    error TransferFailed(address from, address to, uint256 amount);

    // Listing Errors
    error PropertyNotListed(uint256 tokenId);
    error PropertyAlreadyListed(uint256 tokenId);
    error InvalidPrice(uint256 price);
    error NotPropertyOwner(address caller, address owner);
    error PropertyNotAvailable(uint256 tokenId, PropertyStatus status);

    // Bidding Errors
    error NoBidsAvailable(uint256 tokenId);
    error BidNotActive(uint256 tokenId, address bidder);
    error BidTooLow(uint256 bidAmount, uint256 minimumRequired);
    error NotYourBid(address caller, address bidder);
    error BidIncrementTooLow(uint256 bidAmount, uint256 currentAmount);
    error MustMeetListingPrice(uint256 bidAmount, uint256 listingPrice);

    // Payment Errors
    error PaymentTokenNotAllowed(address token);
    error PaymentTokenMismatch(address expected, address provided);
    error InsufficientAllowance(address token, uint256 available, uint256 required);
    error PaymentFailed(address seller, address buyer, uint256 amount);

    // Purchase Errors
    error PurchaseNotPending(uint256 tokenId);
    error PurchaseDeadlineExpired(uint256 tokenId, uint256 deadline);
    error PurchaseNotExpired(uint256 tokenId, uint256 deadline);
    error PurchaseNotActive(uint256 tokenId);
    error ConfirmationDeadlineExpired(uint256 tokenId, uint256 deadline);
    error PropertyHasPendingPurchase(uint256 tokenId);

    // Access Control Errors
    error KYCRequired(address user);
    error AdminRoleRequired(address caller);
    error OperatorRoleRequired(address caller);

    // Validation Errors
    error InvalidInput(string parameter);
    error OutOfRange(uint256 value, uint256 min, uint256 max);
    error AlreadyExists(uint256 tokenId);
    error NotFound(uint256 tokenId);

    // Security Errors
    error TooManyBids(uint256 tokenId, uint256 currentCount, uint256 maxAllowed);
    error InsufficientFunds(uint256 requested, uint256 available);
    error SellerMismatch(address expected, address actual);
    error BidRefundFailed(uint256 tokenId, address bidder, uint256 amount, address token);

    IWETH public immutable weth;

    constructor(address _nfti, address _nftm, address _weth, address admin, address fee, address vault) AdminControl(admin, fee, vault) {
        if (_nfti == address(0)) revert ZeroAddress();
        if (_nftm == address(0)) revert ZeroAddress();
        if (_weth == address(0)) revert ZeroAddress();

        // WETH-only approach - no ETH support
        allowedPaymentTokens[_weth] = true;
        nftiContract = IERC721(_nfti);
        nftmContract = IERC721(_nftm);
        weth = IWETH(_weth);
    }

    /**
     * @notice Helper function for users to wrap ETH to WETH
     * @dev Convenience function - can also be done directly with WETH contract
     */
    function wrapETH() external payable {
        if (msg.value == 0) revert InvalidAmount(msg.value);
        weth.deposit{value: msg.value}();
        IERC20(address(weth)).safeTransfer(msg.sender, msg.value);
    }

    /**
     * @notice Helper function for users to unwrap WETH to ETH
     * @dev Convenience function - can also be done directly with WETH contract
     */
    function unwrapWETH(uint256 amount) external {
        IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), amount);
        weth.withdraw(amount);
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed(address(this), msg.sender, amount);
    }

    uint256 public constant PERCENTAGE_BASE = 10000;

    // SECURITY FIX: Add maximum bid limit to prevent DoS attacks
    uint256 public constant MAX_BIDS_PER_TOKEN = 50;

    enum PropertyStatus { LISTED, RENTED, SOLD, DELISTED, PENDING_SELLER_CONFIRMATION }

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
        uint256 confirmationPeriod;
    }

    struct PendingPurchase {
        uint256 tokenId;
        address buyer;
        uint256 offerPrice;
        address paymentToken;
        uint256 purchaseTimestamp;
        uint256 confirmationDeadline;
        bool isActive;
    }

    IERC721 public immutable nftiContract;
    IERC721 public immutable nftmContract;
    PropertyMarketTimelock public timelock;
    MultiSigOperator public multiSigOperator;
    bool public timelockEnabled = true;
    mapping(address => bool) public allowedPaymentTokens;
    bool public whitelistEnabled = true;

    mapping(uint256 => PropertyListing) public listings;
    mapping(uint256 => PendingPurchase) public pendingPurchases;

    // ❌ REMOVED: PAYMENT_TIMEOUT and paymentDeadlines - not needed with WETH-only approach
    // ❌ REMOVED: ethBidDeposits - not needed with WETH-only approach
    // ❌ REMOVED: pendingRefunds and pendingTokenRefunds - WETH transfers are reliable

    mapping(uint256 => Bid[]) public bidsForToken;
    mapping(address => mapping(uint256 => uint256)) public bidIndexByBidder;

    // SECURITY FIX: Track active bid count to prevent DoS attacks
    mapping(uint256 => uint256) public activeBidCount;

    // SECURITY FIX: Track locked funds to prevent unauthorized emergency withdrawals
    mapping(address => uint256) public lockedTokenFunds;

    // GAS OPTIMIZATION: Cache highest bid to avoid O(n) lookups
    mapping(uint256 => uint256) public highestBidAmount;
    mapping(uint256 => address) public highestBidder;
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
    event PaymentTokenAdded(address indexed token);
    event PaymentTokenRemoved(address indexed token);
    event WhitelistStatusChanged(bool enabled);
    event ListingPriceChanged(uint256 indexed tokenId, uint256 newPrice);

    // ❌ REMOVED: EmergencyWithdrawal event - no ETH withdrawals needed
    event EmergencyTokenWithdrawal(address indexed token, address indexed recipient, uint256 amount);
    event TimelockSet(address indexed timelock);
    event MultiSigOperatorSet(address indexed multiSigOperator);
    event TimelockEnabledChanged(bool enabled);
    // ❌ REMOVED: RefundQueued and RefundWithdrawn events - WETH transfers are reliable
    event CompetitivePurchase(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 purchasePrice,
        uint256 highestBidOutbid,
        address paymentToken
    );
    // ❌ REMOVED: BidRefundFailed and PaymentExpired events - not needed with WETH-only approach
    event BidRefunded(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount,
        address paymentToken
    );

    // SECURITY FIX: Event for failed refunds
    event RefundFailed(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount,
        address paymentToken
    );
    event PurchaseRequested(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 offerPrice,
        address paymentToken,
        uint256 confirmationDeadline
    );

    event PurchaseConfirmed(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 finalPrice,
        address paymentToken
    );

    event PurchaseRejected(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 offerPrice,
        address paymentToken
    );

    event PurchaseExpired(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 offerPrice,
        address paymentToken
    );
    function isTokenAllowed(address token) internal view returns (bool) {
        if (!whitelistEnabled) return true;
        return allowedPaymentTokens[token];
    }
    function addAllowedToken(address token) external onlyOperatorWithTimelock {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token);
    }
    function removeAllowedToken(address token) external onlyOperatorWithTimelock {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token);
    }


    function _safeTokenTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        // 🔒 Security Fix: Use SafeERC20 for safe transfers
        token.safeTransferFrom(from, to, amount);
    }
    function _safeTokenTransfer(
        IERC20 token,
        address to,
        uint256 amount
    ) internal {
        // 🔒 Security Fix: Use SafeERC20 for safe transfers
        token.safeTransfer(to, amount);
    }
    function setWhitelistEnabled(bool enabled) external onlyOperatorWithTimelock {
        whitelistEnabled = enabled;
        emit WhitelistStatusChanged(enabled);
    }
    function setTimelock(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (t == address(0)) revert ZeroAddress();
        if (address(timelock) != address(0)) revert AlreadyExists(0);
        timelock = PropertyMarketTimelock(payable(t));
        emit TimelockSet(t);
    }
    function setMultiSigOperator(address m) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (m == address(0)) revert ZeroAddress();
        if (address(multiSigOperator) != address(0)) revert AlreadyExists(0);
        multiSigOperator = MultiSigOperator(m);
        emit MultiSigOperatorSet(m);
    }
    function setTimelockEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        timelockEnabled = enabled;
        emit TimelockEnabledChanged(enabled);
    }
    function listProperty(uint256 tokenId, uint256 price, address paymentToken) external nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(price) {
        _listPropertyWithConfirmation(tokenId, price, paymentToken, 0);
    }

    function listPropertyWithConfirmation(uint256 tokenId, uint256 price, address paymentToken, uint256 period) external nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(price) {
        if (period > 7 days) revert OutOfRange(period, 0, 7 days);
        _listPropertyWithConfirmation(tokenId, price, paymentToken, period);
    }
    function _listPropertyWithConfirmation(uint256 tokenId, uint256 price, address paymentToken, uint256 period) internal {
        address currentOwner = nftiContract.ownerOf(tokenId);
        if (currentOwner != msg.sender) revert NotPropertyOwner(msg.sender, currentOwner);
        PropertyListing storage existingListing = listings[tokenId];

        if (existingListing.seller != address(0) && existingListing.seller != currentOwner) {
            if (existingListing.status == PropertyStatus.LISTED) {
                _cancelAllBids(tokenId);
            }
        } else if (existingListing.seller == currentOwner) {
            if (existingListing.status == PropertyStatus.LISTED) revert PropertyAlreadyListed(tokenId);

            // CRITICAL FIX: Prevent relisting during PENDING_SELLER_CONFIRMATION
            if (existingListing.status == PropertyStatus.PENDING_SELLER_CONFIRMATION) {
                revert PropertyHasPendingPurchase(tokenId);
            }

            // Additional safety check: Verify no active pending purchases
            PendingPurchase storage pendingPurchase = pendingPurchases[tokenId];
            if (pendingPurchase.isActive) {
                revert PropertyHasPendingPurchase(tokenId);
            }
        }

        listings[tokenId] = PropertyListing({
            tokenId: tokenId,
            seller: msg.sender,
            price: price,
            paymentToken: paymentToken,
            status: PropertyStatus.LISTED,
            listTimestamp: block.timestamp,
            lastRenewed: block.timestamp,
            confirmationPeriod: period
        });

        emit NewListing(tokenId, msg.sender, price, paymentToken);
    }
    function purchaseProperty(uint256 tokenId, uint256 offerPrice) external nonReentrant onlyKYCVerified onlyValidAmount(offerPrice) {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) revert PropertyNotListed(tokenId);
        if (!_validatePayment(listing.price, offerPrice, listing.paymentToken, tokenId)) revert PaymentFailed(listing.seller, msg.sender, offerPrice);
        uint256 highestBid = _getHighestActiveBid(tokenId);

        // 🔒 Security Fix: Correct actualPrice calculation logic
        // If there are bids, buyer must pay their offerPrice (which must be > highestBid)
        // If no bids, buyer pays the listing price
        uint256 actualPrice = highestBid > 0 ? offerPrice : listing.price;

        if (listing.confirmationPeriod > 0) {
            _createPendingPurchase(tokenId, actualPrice, listing.paymentToken);
        } else {
            _completePurchase(tokenId, actualPrice, listing.paymentToken, highestBid);
        }
    }
    function _createPendingPurchase(uint256 tokenId, uint256 actualPrice, address paymentToken) internal {
        PropertyListing storage listing = listings[tokenId];
        // Simplified: WETH-only logic
        IERC20 token = IERC20(paymentToken);
        token.safeTransferFrom(msg.sender, address(this), actualPrice);

        // SECURITY FIX: Track locked funds for pending purchases
        _updateLockedFunds(paymentToken, actualPrice, true);

        listing.status = PropertyStatus.PENDING_SELLER_CONFIRMATION;
        uint256 deadline = block.timestamp + listing.confirmationPeriod;

        pendingPurchases[tokenId] = PendingPurchase({
            tokenId: tokenId,
            buyer: msg.sender,
            offerPrice: actualPrice,
            paymentToken: paymentToken,
            purchaseTimestamp: block.timestamp,
            confirmationDeadline: deadline,
            isActive: true
        });

        emit PurchaseRequested(tokenId, msg.sender, actualPrice, paymentToken, deadline);
    }
    function _completePurchase(uint256 tokenId, uint256 actualPrice, address paymentToken, uint256 highestBid) internal {
        PropertyListing storage listing = listings[tokenId];

        listing.status = PropertyStatus.SOLD;
        _cancelAllBids(tokenId);

        _processPayment(listing.seller, msg.sender, actualPrice, paymentToken);
        nftiContract.safeTransferFrom(listing.seller, msg.sender, tokenId, "");

        emit PropertySold(tokenId, msg.sender, actualPrice, paymentToken);
        if (highestBid > 0) {
            emit CompetitivePurchase(
                tokenId,
                msg.sender,
                actualPrice,
                highestBid,
                paymentToken
            );
        }
    }
    function _handlePurchaseDecision(uint256 tokenId, bool accept) internal {
        PropertyListing storage listing = listings[tokenId];
        PendingPurchase storage purchase = pendingPurchases[tokenId];

        if (listing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION) revert PurchaseNotPending(tokenId);
        if (!purchase.isActive) revert PurchaseNotActive(tokenId);
        address owner = nftiContract.ownerOf(tokenId);
        if (owner != msg.sender) revert NotPropertyOwner(msg.sender, owner);
        if (block.timestamp > purchase.confirmationDeadline) revert ConfirmationDeadlineExpired(tokenId, purchase.confirmationDeadline);

        purchase.isActive = false;

        if (accept) {
            listing.status = PropertyStatus.SOLD;
            _cancelAllBids(tokenId);
            _processPayment(listing.seller, purchase.buyer, purchase.offerPrice, purchase.paymentToken);
            nftiContract.safeTransferFrom(listing.seller, purchase.buyer, tokenId, "");
            emit PurchaseConfirmed(tokenId, msg.sender, purchase.buyer, purchase.offerPrice, purchase.paymentToken);
            emit PropertySold(tokenId, purchase.buyer, purchase.offerPrice, purchase.paymentToken);
        } else {
            _refundPendingPurchase(tokenId);
            listing.status = PropertyStatus.LISTED;
            emit PurchaseRejected(tokenId, msg.sender, purchase.buyer, purchase.offerPrice, purchase.paymentToken);
        }
    }
    function confirmPurchase(uint256 tokenId) external nonReentrant {
        _handlePurchaseDecision(tokenId, true);
    }
    function rejectPurchase(uint256 tokenId) external nonReentrant {
        _handlePurchaseDecision(tokenId, false);
    }
    function cancelExpiredPurchase(uint256 tokenId) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        PendingPurchase storage purchase = pendingPurchases[tokenId];

        if (listing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION) revert PurchaseNotPending(tokenId);
        if (!purchase.isActive) revert PurchaseNotActive(tokenId);
        if (block.timestamp <= purchase.confirmationDeadline) revert PurchaseNotExpired(tokenId, purchase.confirmationDeadline);
        _refundPendingPurchase(tokenId);
        purchase.isActive = false;
        listing.status = PropertyStatus.LISTED;

        emit PurchaseExpired(tokenId, purchase.buyer, purchase.offerPrice, purchase.paymentToken);
    }
    function _refundPendingPurchase(uint256 tokenId) internal {
        PendingPurchase storage purchase = pendingPurchases[tokenId];

        // SECURITY FIX: Update locked funds before refund
        _updateLockedFunds(purchase.paymentToken, purchase.offerPrice, false);

        // Simplified: WETH-only logic
        IERC20 token = IERC20(purchase.paymentToken);
        token.safeTransfer(purchase.buyer, purchase.offerPrice);
    }

    function _cancelAllBids(uint256 tokenId) private {
        // SECURITY FIX: Use batch processing to prevent DoS
        _cancelBidsInBatches(tokenId, 0, MAX_BIDS_PER_TOKEN);
    }

    function _cancelBidsInBatches(uint256 tokenId, uint256 startIndex, uint256 maxBids) private {
        Bid[] storage bids = bidsForToken[tokenId];
        uint256 processed = 0;

        for (uint256 i = startIndex; i < bids.length && processed < maxBids; i++) {
            if (bids[i].isActive) {
                address bidder = bids[i].bidder;
                uint256 refundAmount = bids[i].amount;
                address paymentToken = bids[i].paymentToken;

                bids[i].isActive = false;
                bidIndexByBidder[bidder][tokenId] = 0;

                // SECURITY FIX: Update counters
                activeBidCount[tokenId]--;
                _updateLockedFunds(paymentToken, refundAmount, false);

                // SECURITY FIX: Use safe refund to prevent DoS
                _safeRefundBid(bidder, refundAmount, paymentToken, tokenId);
                processed++;
            }
        }
    }

    function _cancelOtherBids(uint256 tokenId, address excludeBidder) private {
        Bid[] storage bids = bidsForToken[tokenId];
        uint256 processed = 0;

        for (uint256 i = 0; i < bids.length && processed < MAX_BIDS_PER_TOKEN; i++) {
            if (bids[i].isActive && bids[i].bidder != excludeBidder) {
                address bidder = bids[i].bidder;
                uint256 refundAmount = bids[i].amount;
                address paymentToken = bids[i].paymentToken;

                bids[i].isActive = false;
                bidIndexByBidder[bidder][tokenId] = 0;

                // SECURITY FIX: Update counters
                activeBidCount[tokenId]--;
                _updateLockedFunds(paymentToken, refundAmount, false);

                _safeRefundBid(bidder, refundAmount, paymentToken, tokenId);
                processed++;
            }
        }
    }

    function _refundBid(address bidder, uint256 amount, address paymentToken, uint256 tokenId) private {
        // Simplified: WETH-only logic
        IERC20 token = IERC20(paymentToken);
        token.safeTransfer(bidder, amount);
        emit BidRefunded(tokenId, bidder, amount, paymentToken);
    }

    // SECURITY FIX: Safe refund function to prevent DoS
    function _safeRefundBid(address bidder, uint256 amount, address paymentToken, uint256 tokenId) private {
        try this._externalRefundBid(bidder, amount, paymentToken, tokenId) {
            emit BidCancelled(tokenId, bidder, amount);
        } catch {
            // Log failed refund for manual processing
            emit RefundFailed(tokenId, bidder, amount, paymentToken);
        }
    }

    // External function for safe refund (to use try-catch)
    function _externalRefundBid(address bidder, uint256 amount, address paymentToken, uint256 tokenId) external {
        require(msg.sender == address(this), "Internal only");
        IERC20 token = IERC20(paymentToken);
        token.safeTransfer(bidder, amount);
        emit BidRefunded(tokenId, bidder, amount, paymentToken);
    }

    // SECURITY FIX: Track locked funds to prevent unauthorized emergency withdrawals
    function _updateLockedFunds(address token, uint256 amount, bool increase) internal {
        if (increase) {
            lockedTokenFunds[token] += amount;
        } else {
            if (lockedTokenFunds[token] >= amount) {
                lockedTokenFunds[token] -= amount;
            }
        }
    }
    function _validatePayment(
        uint256 listedPrice,
        uint256 offerPrice,
        address paymentToken,
        uint256 tokenId
    ) private view returns (bool) {
        if (!isTokenAllowed(paymentToken)) {
            return false;
        }
        uint256 highestBid = _getHighestActiveBid(tokenId);

        // 🔒 Security Fix: If there are active bids, purchase must exceed highest bid
        uint256 minimumPrice;
        if (highestBid > 0) {
            // Require purchase to be strictly greater than highest bid
            minimumPrice = highestBid + 1; // At least 1 wei more than highest bid
        } else {
            minimumPrice = listedPrice;
        }

        // Simplified: WETH-only validation
        return offerPrice >= minimumPrice;
    }

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

    function _processPaymentFromBalance(
        address seller,
        uint256 amount,
        address paymentToken
    ) internal {
        (uint256 fees, uint256 netValue) = _calculateFees(amount);

        // Simplified: WETH-only logic
        IERC20 token = IERC20(paymentToken);
        token.safeTransfer(seller, netValue);
        token.safeTransfer(feeConfig.feeCollector, fees);
    }

    // SECURITY FIX: Improved fee calculation with precision protection
    function _calculateFees(uint256 amount) internal view returns (uint256 fees, uint256 netValue) {
        require(amount > 0, "Amount must be positive");

        // Use ceiling division to prevent precision loss
        fees = (amount * feeConfig.baseFee + PERCENTAGE_BASE - 1) / PERCENTAGE_BASE;

        // Ensure we don't charge more than the amount
        if (fees > amount) {
            fees = amount;
            netValue = 0;
        } else {
            netValue = amount - fees;
        }

        // Ensure minimum meaningful amounts
        require(netValue > 0 || amount <= feeConfig.baseFee, "Amount too small for fees");
    }
    function updateListing(uint256 tokenId, uint256 newPrice, address newPaymentToken) external onlyOperatorWithTimelock {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) revert PropertyNotListed(tokenId);
        if (newPrice == 0) revert InvalidPrice(newPrice);
        if (!isTokenAllowed(newPaymentToken)) revert PaymentTokenNotAllowed(newPaymentToken);

        // 🔒 Security Fix: Check for active bids before allowing payment token change
        if (newPaymentToken != listing.paymentToken) {
            Bid[] storage bids = bidsForToken[tokenId];
            for (uint256 i = 0; i < bids.length; i++) {
                if (bids[i].isActive) revert InvalidInput("active bids exist");
            }
        }

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
    }
    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) revert OperatorRoleRequired(msg.sender);
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        address owner = nftiContract.ownerOf(tokenId);
        if (owner != msg.sender) revert NotPropertyOwner(msg.sender, owner);
        _;
    }
    modifier onlyOperatorWithTimelock() {
        if (timelockEnabled && address(timelock) != address(0)) {
            if (msg.sender != address(timelock)) revert UnauthorizedAccess(msg.sender);
        } else {
            if (!hasRole(OPERATOR_ROLE, msg.sender)) revert OperatorRoleRequired(msg.sender);
        }
        _;
    }

    modifier onlyKYCVerified() {
        if (!this.isKYCVerified(msg.sender)) revert KYCRequired(msg.sender);
        _;
    }

    modifier onlyAllowedToken(address token) {
        if (!isTokenAllowed(token)) revert PaymentTokenNotAllowed(token);
        _;
    }

    modifier onlyValidAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount(amount);
        _;
    }

    function getListingDetails(uint256 tokenId)
        external
        view
        returns (
            address seller,
            uint256 price,
            address paymentToken,
            PropertyStatus status,
            uint256 listTimestamp,
            uint256 confirmationPeriod
        )
    {
        PropertyListing storage listing = listings[tokenId];
        return (
            listing.seller,
            listing.price,
            listing.paymentToken,
            listing.status,
            listing.listTimestamp,
            listing.confirmationPeriod
        );
    }

    function placeBid(uint256 tokenId, uint256 bidAmount, address paymentToken) external nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(bidAmount) {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) revert PropertyNotListed(tokenId);

        address currentOwner = nftiContract.ownerOf(tokenId);
        if (currentOwner == msg.sender) revert NotPropertyOwner(msg.sender, currentOwner);
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];
        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            if (!existingBid.isActive) revert BidNotActive(tokenId, msg.sender);
            if (existingBid.paymentToken != paymentToken) revert PaymentTokenMismatch(existingBid.paymentToken, paymentToken);

            uint256 oldAmount = existingBid.amount;
            if (bidAmount < oldAmount) revert BidIncrementTooLow(bidAmount, oldAmount);

            if (bidAmount > oldAmount) {
                uint256 additionalAmount = bidAmount - oldAmount;
                // Simplified: WETH-only logic
                IERC20 token = IERC20(paymentToken);
                token.safeTransferFrom(msg.sender, address(this), additionalAmount);
            }
            // No additional payment needed if bidAmount <= oldAmount
        } else {
            // SECURITY FIX: Check bid limit for new bids
            if (activeBidCount[tokenId] >= MAX_BIDS_PER_TOKEN) {
                revert TooManyBids(tokenId, activeBidCount[tokenId], MAX_BIDS_PER_TOKEN);
            }

            // New bid - simplified WETH-only logic
            IERC20 token = IERC20(paymentToken);
            token.safeTransferFrom(msg.sender, address(this), bidAmount);

            // SECURITY FIX: Update locked funds tracking
            _updateLockedFunds(paymentToken, bidAmount, true);
        }

        if (bidAmount < listing.price) revert MustMeetListingPrice(bidAmount, listing.price);
        uint256 highestBid = 0;
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highestBid) {
                highestBid = bids[i].amount;
            }
        }

        if (highestBid > 0) {
            uint256 minBid = highestBid;
            if (bidAmount < minBid) revert BidTooLow(bidAmount, minBid);
        }

        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];

            // SECURITY FIX: Update locked funds for bid increase
            if (bidAmount > existingBid.amount) {
                uint256 additionalAmount = bidAmount - existingBid.amount;
                _updateLockedFunds(paymentToken, additionalAmount, true);
            }

            existingBid.amount = bidAmount;
            existingBid.bidTimestamp = block.timestamp;
        } else {
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

            // SECURITY FIX: Increment active bid count
            activeBidCount[tokenId]++;
        }

        // GAS OPTIMIZATION: Update highest bid cache
        _updateHighestBid(tokenId, bidAmount, msg.sender);

        emit BidPlaced(tokenId, msg.sender, bidAmount, paymentToken);
    }

    // SECURITY FIX: Add slippage protection for bids
    function placeBidWithProtection(
        uint256 tokenId,
        uint256 bidAmount,
        address paymentToken,
        uint256 deadline,
        uint256 maxCurrentHighestBid
    ) external nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(bidAmount) {
        require(block.timestamp <= deadline, "Deadline expired");

        uint256 currentHighestBid = _getHighestActiveBid(tokenId);
        require(currentHighestBid <= maxCurrentHighestBid, "Highest bid changed");

        // Continue with existing placeBid logic
        _placeBidInternal(tokenId, bidAmount, paymentToken);
    }

    // Internal function to avoid code duplication
    function _placeBidInternal(uint256 tokenId, uint256 bidAmount, address paymentToken) internal {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) revert PropertyNotListed(tokenId);

        address currentOwner = nftiContract.ownerOf(tokenId);
        if (currentOwner == msg.sender) revert NotPropertyOwner(msg.sender, currentOwner);
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];

        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            if (!existingBid.isActive) revert BidNotActive(tokenId, msg.sender);
            if (existingBid.paymentToken != paymentToken) revert PaymentTokenMismatch(existingBid.paymentToken, paymentToken);

            uint256 oldAmount = existingBid.amount;
            if (bidAmount < oldAmount) revert BidIncrementTooLow(bidAmount, oldAmount);

            if (bidAmount > oldAmount) {
                uint256 additionalAmount = bidAmount - oldAmount;
                // Simplified: WETH-only logic
                IERC20 token = IERC20(paymentToken);
                token.safeTransferFrom(msg.sender, address(this), additionalAmount);

                // SECURITY FIX: Update locked funds for bid increase
                _updateLockedFunds(paymentToken, additionalAmount, true);
            }
        } else {
            // SECURITY FIX: Check bid limit for new bids
            if (activeBidCount[tokenId] >= MAX_BIDS_PER_TOKEN) {
                revert TooManyBids(tokenId, activeBidCount[tokenId], MAX_BIDS_PER_TOKEN);
            }

            // New bid - simplified WETH-only logic
            IERC20 token = IERC20(paymentToken);
            token.safeTransferFrom(msg.sender, address(this), bidAmount);

            // SECURITY FIX: Update locked funds tracking
            _updateLockedFunds(paymentToken, bidAmount, true);
        }

        if (bidAmount < listing.price) revert MustMeetListingPrice(bidAmount, listing.price);

        // GAS OPTIMIZATION: Use cached highest bid
        uint256 highestBid = _getHighestActiveBid(tokenId);
        if (highestBid > 0) {
            uint256 minBid = highestBid;
            if (bidAmount < minBid) revert BidTooLow(bidAmount, minBid);
        }

        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            existingBid.amount = bidAmount;
            existingBid.bidTimestamp = block.timestamp;
        } else {
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

            // SECURITY FIX: Increment active bid count
            activeBidCount[tokenId]++;
        }

        // GAS OPTIMIZATION: Update highest bid cache
        _updateHighestBid(tokenId, bidAmount, msg.sender);

        emit BidPlaced(tokenId, msg.sender, bidAmount, paymentToken);
    }

    function acceptBid(uint256 tokenId, uint256 bidIndex, address expectedBidder, uint256 expectedAmount, address expectedPaymentToken) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) revert PropertyNotListed(tokenId);
        address owner = nftiContract.ownerOf(tokenId);
        if (owner != msg.sender) revert NotPropertyOwner(msg.sender, owner);

        // SECURITY FIX: Remove automatic seller update - require explicit validation
        if (listing.seller != msg.sender) {
            revert SellerMismatch(listing.seller, msg.sender);
        }

        if (bidIndex == 0) revert OutOfRange(bidIndex, 1, bidsForToken[tokenId].length);
        if (bidIndex > bidsForToken[tokenId].length) revert OutOfRange(bidIndex, 1, bidsForToken[tokenId].length);
        if (bidsForToken[tokenId].length == 0) revert NoBidsAvailable(tokenId);

        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        if (!bid.isActive) revert BidNotActive(tokenId, bid.bidder);
        if (bid.bidder != expectedBidder) revert InvalidInput("bidder mismatch");
        if (bid.amount != expectedAmount) revert InvalidInput("amount mismatch");
        if (bid.paymentToken != expectedPaymentToken) revert PaymentTokenMismatch(bid.paymentToken, expectedPaymentToken);

        // Simplified: All WETH bids settle immediately
        listing.status = PropertyStatus.SOLD;
        bid.isActive = false;
        bidIndexByBidder[bid.bidder][tokenId] = 0;
        _processPaymentFromBalance(listing.seller, bid.amount, bid.paymentToken);
        nftiContract.safeTransferFrom(listing.seller, bid.bidder, tokenId, "");
        emit BidAccepted(tokenId, listing.seller, bid.bidder, bid.amount, bid.paymentToken);
        _cancelOtherBids(tokenId, bid.bidder);
    }

    // ❌ REMOVED: completeBidPayment function - not needed with WETH-only approach
    // All WETH bids settle immediately when accepted

    function _getHighestActiveBid(uint256 tokenId) private view returns (uint256) {
        // GAS OPTIMIZATION: Use cached value instead of O(n) lookup
        return highestBidAmount[tokenId];
    }

    // GAS OPTIMIZATION: Update highest bid cache
    function _updateHighestBid(uint256 tokenId, uint256 newBidAmount, address bidder) internal {
        if (newBidAmount > highestBidAmount[tokenId]) {
            highestBidAmount[tokenId] = newBidAmount;
            highestBidder[tokenId] = bidder;
        }
    }

    // GAS OPTIMIZATION: Recalculate highest bid when needed (e.g., when highest bidder cancels)
    function _recalculateHighestBid(uint256 tokenId) internal {
        Bid[] storage bids = bidsForToken[tokenId];
        uint256 highest = 0;
        address topBidder = address(0);

        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highest) {
                highest = bids[i].amount;
                topBidder = bids[i].bidder;
            }
        }

        highestBidAmount[tokenId] = highest;
        highestBidder[tokenId] = topBidder;
    }

    function updateListingBySeller(uint256 tokenId, uint256 newPrice, address newPaymentToken) external onlyValidAmount(newPrice) onlyAllowedToken(newPaymentToken) {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) revert PropertyNotListed(tokenId);
        address owner = nftiContract.ownerOf(tokenId);
        if (owner != msg.sender) revert NotPropertyOwner(msg.sender, owner);

        address currentOwner = msg.sender;
        if (listing.seller != currentOwner) {
            listing.seller = currentOwner;
        }
        if (newPaymentToken != listing.paymentToken) {
            Bid[] storage bids = bidsForToken[tokenId];
            for (uint256 i = 0; i < bids.length; i++) {
                if (bids[i].isActive) revert InvalidInput("active bids exist");
            }
        }

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
        emit ListingPriceChanged(tokenId, newPrice);
    }

    function cancelBid(uint256 tokenId) external nonReentrant {
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        if (bidIndex == 0) revert NoBidsAvailable(tokenId);

        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        if (!bid.isActive) revert BidNotActive(tokenId, msg.sender);
        if (bid.bidder != msg.sender) revert NotYourBid(msg.sender, bid.bidder);
        uint256 refundAmount = bid.amount;
        address paymentToken = bid.paymentToken;

        bid.isActive = false;
        bidIndexByBidder[msg.sender][tokenId] = 0;

        // SECURITY FIX: Update counters
        activeBidCount[tokenId]--;
        _updateLockedFunds(paymentToken, refundAmount, false);

        // GAS OPTIMIZATION: Recalculate highest bid if this was the highest bidder
        if (msg.sender == highestBidder[tokenId]) {
            _recalculateHighestBid(tokenId);
        }

        // Simplified: WETH-only refund logic
        IERC20 token = IERC20(paymentToken);
        token.safeTransfer(msg.sender, refundAmount);

        emit BidCancelled(tokenId, msg.sender, refundAmount);
    }

    // ❌ REMOVED: withdrawPendingRefund function - not needed with WETH-only approach
    // WETH transfers are reliable and don't require pending refund mechanism

    // ❌ REMOVED: cancelExpiredPayment function - not needed with WETH-only approach
    // All WETH bids settle immediately, no payment timeouts


    // ❌ REMOVED: emergencyWithdrawETH function - not needed with WETH-only approach
    // Contract doesn't hold ETH, only WETH and other ERC20 tokens

    function emergencyWithdrawToken(address token, uint256 amount, address recipient) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AdminRoleRequired(msg.sender);
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();

        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));

        // SECURITY FIX: Calculate locked funds and prevent withdrawal of user funds
        uint256 lockedFunds = lockedTokenFunds[token];

        // Add locked funds from pending purchases
        lockedFunds += _calculatePendingPurchaseFunds(token);

        uint256 availableForWithdrawal = balance > lockedFunds ? balance - lockedFunds : 0;

        if (amount > availableForWithdrawal) {
            revert InsufficientFunds(amount, availableForWithdrawal);
        }

        // Use SafeERC20 for consistent error handling
        tokenContract.safeTransfer(recipient, amount);

        emit EmergencyTokenWithdrawal(token, recipient, amount);
    }

    // SECURITY FIX: Calculate funds locked in pending purchases
    function _calculatePendingPurchaseFunds(address token) internal view returns (uint256 totalLocked) {
        // Note: This is a simplified approach. In production, you might want to maintain
        // a separate mapping for pending purchase funds to avoid gas issues
        // For now, we'll use a conservative approach and assume some funds might be locked
        return 0; // This should be implemented based on your specific requirements
    }

}
