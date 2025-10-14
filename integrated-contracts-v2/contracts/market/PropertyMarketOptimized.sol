// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {AdminControl} from "../governance/AdminControl.sol";
import {PaymentProcessor} from "../libraries/PaymentProcessor.sol";
import {BiddingLibrary} from "../libraries/BiddingLibrary.sol";
import {ErrorCodes} from "../libraries/ErrorCodes.sol";

/**
 * @title PropertyMarketOptimized
 * @notice Optimized version of PropertyMarket with reduced contract size
 * @dev Key optimizations:
 * - Packed struct fields to reduce storage slots
 * - Extracted bidding logic to BiddingLibrary
 * - Merged similar events and validations
 * - Optimized modifiers and internal functions
 */
contract PropertyMarketOptimized is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BiddingLibrary for BiddingLibrary.Bid[];

    uint256 public constant PERCENTAGE_BASE = 10000;

    enum PropertyStatus {
        LISTED,                         // 0
        SOLD,                          // 1
        DELISTED,                      // 2
        PENDING_SELLER_CONFIRMATION    // 3
    }

    // Optimized PropertyListing structure with packed fields
    struct PropertyListing {
        address seller;                 // 20 bytes
        address paymentToken;           // 20 bytes
        uint256 price;                  // 32 bytes
        uint256 tokenId;                // 32 bytes
        uint64 listTimestamp;           // 8 bytes - packed
        uint64 lastRenewed;             // 8 bytes - packed
        uint32 confirmationPeriod;      // 4 bytes - packed (max ~136 years in seconds)
        uint8 status;                   // 1 byte - packed (PropertyStatus enum)
    }

    // Optimized PendingPurchase structure with packed fields
    struct PendingPurchase {
        address buyer;                  // 20 bytes
        address paymentToken;           // 20 bytes
        uint256 offerPrice;             // 32 bytes
        uint256 tokenId;                // 32 bytes
        uint64 purchaseTimestamp;       // 8 bytes - packed
        uint64 confirmationDeadline;    // 8 bytes - packed
        bool isActive;                  // 1 byte - packed
    }

    IERC721 public immutable nftiContract;
    IERC721 public immutable nftmContract;
    AdminControl public immutable adminControl;

    address public immutable governanceExecutor;

    // Function identifiers for fine-grained pause control
    uint256 public constant FN_LIST = 1;
    uint256 public constant FN_PURCHASE = 2;
    uint256 public constant FN_BID = 3;
    uint256 public constant FN_ACCEPT_BID = 4;
    uint256 public constant FN_CANCEL_BID = 5;
    uint256 public constant FN_CONFIRM = 6;
    uint256 public constant FN_REJECT = 7;
    uint256 public constant FN_CANCEL_EXPIRED = 8;
    uint256 public constant FN_ADMIN_UPDATE_LISTING = 100;
    uint256 public constant FN_ALLOWED_TOKEN_UPDATE = 101;

    mapping(address => bool) public allowedPaymentTokens;
    mapping(uint256 => PropertyListing) public listings;
    mapping(uint256 => PendingPurchase) public pendingPurchases;
    mapping(uint256 => BiddingLibrary.Bid[]) public bidsForToken;
    mapping(address => mapping(uint256 => uint256)) public bidIndexByBidder;
    mapping(address => mapping(address => uint256)) public refundableBalances; // bidder => token => amount


    // Merged events to reduce contract size
    event ListingEvent(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        address paymentToken,
        uint8 eventType  // 0=NewListing, 1=Updated, 2=PriceChanged
    );

    event PropertySold(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 price,
        address paymentToken,
        bool wasCompetitive
    );

    event PurchaseStatusChanged(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 offerPrice,
        address paymentToken,
        uint64 deadline,
        uint8 statusType  // 0=Requested, 1=Confirmed, 2=Rejected, 3=Expired
    );

    event PaymentTokenUpdated(address indexed token, bool allowed);
    event EmergencyTokenWithdrawal(address indexed token, address indexed recipient, uint256 amount);

    error DirectEthTransferNotAllowed();
    error InvalidInput();

    constructor(
        address _nfti,
        address _nftm,
        AdminControl _adminControl,
        address _governanceExecutor
    ) {
        if (
            _nfti == address(0) ||
            _nftm == address(0) ||
            address(_adminControl) == address(0) ||
            _governanceExecutor == address(0)
        ) {
            revert InvalidInput();
        }

        nftiContract = IERC721(_nfti);
        nftmContract = IERC721(_nftm);
        adminControl = _adminControl;
        governanceExecutor = _governanceExecutor;
    }

    // ========== Token Management ==========

    function addAllowedToken(address token) external whenSystemActive whenFunctionActive(FN_ALLOWED_TOKEN_UPDATE) onlyAdmin {
        require(token != address(0), ErrorCodes.E001);
        allowedPaymentTokens[token] = true;
        emit PaymentTokenUpdated(token, true);
    }

    function removeAllowedToken(address token) external whenSystemActive whenFunctionActive(FN_ALLOWED_TOKEN_UPDATE) onlyAdmin {
        require(token != address(0), ErrorCodes.E001);
        allowedPaymentTokens[token] = false;
        emit PaymentTokenUpdated(token, false);
    }

    // ========== Listing Functions ==========

    function listProperty(
        uint256 tokenId,
        uint256 price,
        address paymentToken
    ) external nonReentrant whenSystemActive whenFunctionActive(FN_LIST) onlyKYCVerified {
        _listPropertyInternal(tokenId, price, paymentToken, 0);
    }

    function listPropertyWithConfirmation(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 period
    ) external nonReentrant whenSystemActive whenFunctionActive(FN_LIST) onlyKYCVerified {
        require(period <= 7 days, ErrorCodes.E607);
        _listPropertyInternal(tokenId, price, paymentToken, period);
    }

    function _listPropertyInternal(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 period
    ) internal {
        // Combined validation
        require(
            price > 0 &&
            allowedPaymentTokens[paymentToken] &&
            nftiContract.ownerOf(tokenId) == msg.sender,
            ErrorCodes.E001
        );

        PropertyListing storage existingListing = listings[tokenId];

        // Cancel bids if listing exists and seller changed
        if (existingListing.seller != address(0) &&
            existingListing.seller != msg.sender &&
            existingListing.status == uint8(PropertyStatus.LISTED)) {
            BiddingLibrary.cancelAllBids(bidsForToken[tokenId], bidIndexByBidder, tokenId, refundableBalances);
        } else if (existingListing.seller == msg.sender) {
            require(existingListing.status != uint8(PropertyStatus.LISTED), ErrorCodes.E102);
        }

        // Create optimized listing
        listings[tokenId] = PropertyListing({
            seller: msg.sender,
            paymentToken: paymentToken,
            price: price,
            tokenId: tokenId,
            listTimestamp: uint64(block.timestamp),
            lastRenewed: uint64(block.timestamp),
            confirmationPeriod: uint32(period),
            status: uint8(PropertyStatus.LISTED)
        });

        emit ListingEvent(tokenId, msg.sender, price, paymentToken, 0);
    }

    function updateListingBySeller(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    ) external whenSystemActive whenFunctionActive(FN_LIST) {
        PropertyListing storage listing = listings[tokenId];
        require(
            newPrice > 0 &&
            allowedPaymentTokens[newPaymentToken] &&
            listing.status == uint8(PropertyStatus.LISTED) &&
            nftiContract.ownerOf(tokenId) == msg.sender,
            ErrorCodes.E001
        );

        // Update seller if ownership changed
        if (listing.seller != msg.sender) {
            listing.seller = msg.sender;
        }

        // Check for active bids if payment token changed
        if (newPaymentToken != listing.paymentToken) {
            BiddingLibrary.Bid[] storage bids = bidsForToken[tokenId];
            uint256 length = bids.length;
            for (uint256 i = 0; i < length; i++) {
                require(!bids[i].isActive, ErrorCodes.E911);
            }
        }

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = uint64(block.timestamp);

        emit ListingEvent(tokenId, msg.sender, newPrice, newPaymentToken, 1);
    }

    // ========== Purchase Functions ==========

    function purchaseProperty(
        uint256 tokenId,
        uint256 offerPrice
    ) external nonReentrant whenSystemActive whenFunctionActive(FN_PURCHASE) onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        require(
            offerPrice > 0 &&
            listing.status == uint8(PropertyStatus.LISTED),
            ErrorCodes.E001
        );

        uint256 highestBid = BiddingLibrary.getHighestActiveBid(bidsForToken[tokenId]);
        uint256 minimumPrice = highestBid > 0 ? highestBid : listing.price;
        require(
            offerPrice >= minimumPrice &&
            allowedPaymentTokens[listing.paymentToken],
            ErrorCodes.E005
        );

        uint256 actualPrice = highestBid > 0 ? offerPrice : listing.price;

        if (listing.confirmationPeriod > 0) {
            _createPendingPurchase(tokenId, actualPrice, listing.paymentToken, listing.confirmationPeriod);
        } else {
            _completePurchase(tokenId, actualPrice, listing.paymentToken, highestBid > 0);
        }
    }

    function _createPendingPurchase(
        uint256 tokenId,
        uint256 actualPrice,
        address paymentToken,
        uint32 confirmationPeriod
    ) internal {
        PropertyListing storage listing = listings[tokenId];

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), actualPrice);

        listing.status = uint8(PropertyStatus.PENDING_SELLER_CONFIRMATION);
        uint64 deadline = uint64(block.timestamp) + confirmationPeriod;

        pendingPurchases[tokenId] = PendingPurchase({
            buyer: msg.sender,
            paymentToken: paymentToken,
            offerPrice: actualPrice,
            tokenId: tokenId,
            purchaseTimestamp: uint64(block.timestamp),
            confirmationDeadline: deadline,
            isActive: true
        });

        emit PurchaseStatusChanged(tokenId, msg.sender, actualPrice, paymentToken, deadline, 0);
    }

    function _completePurchase(
        uint256 tokenId,
        uint256 actualPrice,
        address paymentToken,
        bool wasCompetitive
    ) internal {
        PropertyListing storage listing = listings[tokenId];

        listing.status = uint8(PropertyStatus.SOLD);
        BiddingLibrary.cancelAllBids(bidsForToken[tokenId], bidIndexByBidder, tokenId, refundableBalances);

        _processPayment(listing.seller, msg.sender, actualPrice, paymentToken);
        nftiContract.safeTransferFrom(listing.seller, msg.sender, tokenId, "");

        emit PropertySold(tokenId, msg.sender, actualPrice, paymentToken, wasCompetitive);
    }

    function confirmPurchase(uint256 tokenId) external nonReentrant whenSystemActive whenFunctionActive(FN_CONFIRM) {
        _handlePurchaseDecision(tokenId, true);
    }

    function rejectPurchase(uint256 tokenId) external nonReentrant whenSystemActive whenFunctionActive(FN_REJECT) {
        _handlePurchaseDecision(tokenId, false);
    }

    function _handlePurchaseDecision(uint256 tokenId, bool accept) internal {
        PropertyListing storage listing = listings[tokenId];
        PendingPurchase storage purchase = pendingPurchases[tokenId];

        require(
            listing.status == uint8(PropertyStatus.PENDING_SELLER_CONFIRMATION) &&
            purchase.isActive &&
            nftiContract.ownerOf(tokenId) == msg.sender &&
            block.timestamp <= purchase.confirmationDeadline,
            ErrorCodes.E602
        );

        purchase.isActive = false;

        if (accept) {
            listing.status = uint8(PropertyStatus.SOLD);
            BiddingLibrary.cancelAllBids(bidsForToken[tokenId], bidIndexByBidder, tokenId, refundableBalances);

            _processPaymentFromBalance(listing.seller, purchase.offerPrice, purchase.paymentToken);
            nftiContract.safeTransferFrom(listing.seller, purchase.buyer, tokenId, "");

            emit PurchaseStatusChanged(tokenId, purchase.buyer, purchase.offerPrice, purchase.paymentToken, 0, 1);
            emit PropertySold(tokenId, purchase.buyer, purchase.offerPrice, purchase.paymentToken, false);
        } else {
            // CEI: effects before interactions (refund)
            listing.status = uint8(PropertyStatus.LISTED);
            IERC20(purchase.paymentToken).safeTransfer(purchase.buyer, purchase.offerPrice);
            emit PurchaseStatusChanged(tokenId, purchase.buyer, purchase.offerPrice, purchase.paymentToken, 0, 2);
        }
    }

    function cancelExpiredPurchase(uint256 tokenId) external nonReentrant whenSystemActive whenFunctionActive(FN_CANCEL_EXPIRED) {
        PropertyListing storage listing = listings[tokenId];
        PendingPurchase storage purchase = pendingPurchases[tokenId];

        require(
            listing.status == uint8(PropertyStatus.PENDING_SELLER_CONFIRMATION) &&
            purchase.isActive &&
            block.timestamp > purchase.confirmationDeadline,
            ErrorCodes.E602
        );

        // CEI: effects before interactions (refund)
        purchase.isActive = false;
        listing.status = uint8(PropertyStatus.LISTED);
        IERC20(purchase.paymentToken).safeTransfer(purchase.buyer, purchase.offerPrice);

        emit PurchaseStatusChanged(tokenId, purchase.buyer, purchase.offerPrice, purchase.paymentToken, 0, 3);
    }

    // Optional: batched bid cancellation to avoid single-tx O(n) with transfers
    function cancelBidsBatch(
        uint256 tokenId,
        uint256 start,
        uint256 count
    ) external nonReentrant whenSystemActive whenFunctionActive(FN_BID) {
        BiddingLibrary.Bid[] storage bids = bidsForToken[tokenId];
        uint256 len = bids.length;
        require(start < len, ErrorCodes.E001);
        uint256 end = start + count;
        if (end > len) end = len;
        for (uint256 i = start; i < end; i++) {
            if (bids[i].isActive) {
                address bidder = bids[i].bidder;
                uint256 refundAmount = bids[i].amount;
                address paymentToken = bids[i].paymentToken;

                bids[i].isActive = false;
                bidIndexByBidder[bidder][tokenId] = 0;
                refundableBalances[bidder][paymentToken] += refundAmount;
                emit BiddingLibrary.BidCancelled(tokenId, bidder, refundAmount);
            }
        }
    }


    // ========== Bidding Functions ==========

    function placeBid(
        uint256 tokenId,
        uint256 bidAmount,
        address paymentToken
    ) external nonReentrant whenSystemActive whenFunctionActive(FN_BID) onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        require(
            bidAmount > 0 &&
            allowedPaymentTokens[paymentToken] &&
            listing.status == uint8(PropertyStatus.LISTED) &&
            nftiContract.ownerOf(tokenId) != msg.sender,
            ErrorCodes.E001
        );

        BiddingLibrary.placeBid(
            bidsForToken[tokenId],
            bidIndexByBidder,
            tokenId,
            msg.sender,
            bidAmount,
            paymentToken,
            listing.price
        );
    }

    function acceptBid(
        uint256 tokenId,
        uint256 bidIndex,
        address expectedBidder,
        uint256 expectedAmount,
        address expectedPaymentToken
    ) external nonReentrant whenSystemActive whenFunctionActive(FN_ACCEPT_BID) {
        PropertyListing storage listing = listings[tokenId];
        require(
            listing.status == uint8(PropertyStatus.LISTED) &&
            nftiContract.ownerOf(tokenId) == msg.sender &&
            bidIndex > 0 &&
            bidIndex <= bidsForToken[tokenId].length,
            ErrorCodes.E001
        );

        // Update seller if ownership changed
        if (listing.seller != msg.sender) {
            listing.seller = msg.sender;
        }

        BiddingLibrary.Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(
            bid.isActive &&
            bid.bidder == expectedBidder &&
            bid.amount == expectedAmount &&
            bid.paymentToken == expectedPaymentToken,
            ErrorCodes.E501
        );

        listing.status = uint8(PropertyStatus.SOLD);
        bid.isActive = false;
        bidIndexByBidder[bid.bidder][tokenId] = 0;

        _processPaymentFromBalance(listing.seller, bid.amount, bid.paymentToken);
        nftiContract.safeTransferFrom(listing.seller, bid.bidder, tokenId, "");

        emit PropertySold(tokenId, bid.bidder, bid.amount, bid.paymentToken, true);

        BiddingLibrary.cancelOtherBids(bidsForToken[tokenId], bidIndexByBidder, tokenId, bid.bidder, refundableBalances);
    }

    function cancelBid(uint256 tokenId) external nonReentrant whenSystemActive whenFunctionActive(FN_CANCEL_BID) {
        BiddingLibrary.cancelBid(bidsForToken[tokenId], bidIndexByBidder, tokenId, msg.sender, refundableBalances);
    }

    // ========== Payment Processing ==========

    function _processPayment(
        address seller,
        address buyer,
        uint256 amount,
        address paymentToken
    ) internal {
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig();

        PaymentProcessor.processPayment(
            PaymentProcessor.PaymentConfig({
                baseFee: baseFee,
                feeCollector: feeCollector,
                percentageBase: PERCENTAGE_BASE
            }),
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
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig();

        uint256 fees = (amount * baseFee) / PERCENTAGE_BASE;
        uint256 netValue = amount - fees;

        IERC20 token = IERC20(paymentToken);
        token.safeTransfer(seller, netValue);
        token.safeTransfer(feeCollector, fees);
    }

    // ========== Refund Claims ==========
    function claimRefund(address paymentToken) external nonReentrant {
        uint256 amount = refundableBalances[msg.sender][paymentToken];
        require(amount > 0, ErrorCodes.E001);
        refundableBalances[msg.sender][paymentToken] = 0;
        IERC20(paymentToken).safeTransfer(msg.sender, amount);
    }


    // ========== View Functions ==========

    function getListingDetails(uint256 tokenId)
        external
        view
        returns (
            address seller,


            uint256 price,
            address paymentToken,
            uint8 status,
            uint64 listTimestamp,
            uint32 confirmationPeriod
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

    function getHighestBid(uint256 tokenId) external view returns (uint256) {
        return BiddingLibrary.getHighestActiveBid(bidsForToken[tokenId]);
    }

    // ========== Admin Functions ==========

    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    ) external whenSystemActive whenFunctionActive(FN_ADMIN_UPDATE_LISTING) onlyAdmin {
        PropertyListing storage listing = listings[tokenId];
        require(
            listing.status == uint8(PropertyStatus.LISTED) &&
            newPrice > 0 &&
            allowedPaymentTokens[newPaymentToken],
            ErrorCodes.E103
        );

        listing.price = newPrice;

        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = uint64(block.timestamp);

        emit ListingEvent(tokenId, listing.seller, newPrice, newPaymentToken, 1);
    }

    function emergencyWithdrawToken(
        address token,
        uint256 amount,
        address recipient
    ) external onlyGovernance {
        require(token != address(0) && recipient != address(0), ErrorCodes.E915);

        IERC20 tokenContract = IERC20(token);
        require(amount <= tokenContract.balanceOf(address(this)), ErrorCodes.E916);

        tokenContract.safeTransfer(recipient, amount);
        emit EmergencyTokenWithdrawal(token, recipient, amount);
    }

    // ========== Modifiers ==========

    modifier onlyAdmin() {
        require(adminControl.hasRole(adminControl.DEFAULT_ADMIN_ROLE(), msg.sender), ErrorCodes.E401);
        _;
    }

    modifier onlyKYCVerified() {
        require(adminControl.isKYCVerified(msg.sender), ErrorCodes.E403);
        _;
    }

    // Prevent direct ETH transfers
    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }
    // ========== Pause & Governance Modifiers ==========
    modifier whenSystemActive() {
        require(!adminControl.paused(), "Global paused");
        _;
    }

    modifier whenFunctionActive(uint256 functionId) {
        require(!adminControl.functionPaused(functionId), "Function paused");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governanceExecutor, ErrorCodes.E401);
        _;
    }

}

