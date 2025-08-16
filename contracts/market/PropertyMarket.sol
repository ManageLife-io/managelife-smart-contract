// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AdminControl} from "../governance/AdminControl.sol";
import {IManageLifePropertyNFT} from "../interfaces/IManageLifePropertyNFT.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

contract PropertyMarket is ReentrancyGuard, ERC721Holder {
    using SafeERC20 for IERC20;

    //Constants and immutable variables
    //This should never be changed once we agree on a number that is gas-optimized, during testing.
    uint8 private constant TOP_BIDS_COUNT = 10;
    uint256 private constant PERCENTAGE_BASE = 10000;

    //Data Structures
    struct TopBidCandidate {
        address bidder;
        uint128 amount;
        uint64 bidTimestamp;
    }

    struct PropertyListing {
        // Slot 1
        uint256 tokenId; // 32 bytes
        // Slot 2
        uint128 price; // 16 bytes (covers up to ~3.4e38 in wei with 18d decimals)
        uint64 listTimestamp; // 8 bytes (fits ~584B years in seconds)
        uint64 lastRenewed; // 8 bytes
        // Slot 3
        uint64 confirmationPeriod; // 8 bytes (max 18k years, more than enough)
        uint64 biddingActivationCount; // 8 bytes
        uint128 highestBid; // 16 bytes
        // Slot 4
        address seller; // 20 bytes
        address paymentToken; // 20 bytes (will spill to next slot)
        // Slot 5
        address highestBidder; // 20 bytes
        PropertyStatus status; // 1 byte enum
        bool biddingActive; // 1 byte
        // Slot 6+ : topBids array (fixed TopBidCandidate[TOP_BIDS_COUNT])
        TopBidCandidate[TOP_BIDS_COUNT] topBids;
    }

    struct PendingPurchase {
        uint128 price; // slot 0 (16)
        uint64 purchaseTimestamp; // slot 0 (8)
        uint64 confirmationDeadline; // slot 0 (8)
        uint256 tokenId; // slot 1 (32)
        address buyer; // slot 2 (20)
        uint64 fee; // slot 2 (+8) -> 28 used, 4 wasted
        address paymentToken; // slot 3 (20) -> 12 wasted
        address feeCollector; // slot 4 (20) -> 12 wasted
    }

    enum PropertyStatus {
        UNINITIALIZED, //Safety status before a listing is completed.
        LISTED,
        SOLD,
        DELISTED,
        PENDING_SELLER_CONFIRMATION //Also used for escrow period.
    }

    //State Variables
    uint256 public minConfirmationPeriod;
    uint256 public maxConfirmationPeriod;
    uint256 public maxToggleBiddingReactivation;
    uint256 public minimumBidIncrement; // e.g., 50 = 0.5%, 100 = 1%
    IManageLifePropertyNFT public immutable manageLifePropertyNFT;

    //Note: no rebasing or fee-on-transfer tokens allowed!
    mapping(address => bool) public allowedPaymentTokens;
    AdminControl public adminControl;
    mapping(uint256 => PropertyListing) public listings;
    mapping(uint256 => PendingPurchase) public pendingPurchases;

    //Events
    event NewListing(
        uint256 indexed tokenId,
        address indexed seller,
        uint128 price,
        address paymentToken
    );
    event PropertyUnlisted(uint256 indexed tokenId, address indexed seller);
    event PropertySold(
        uint256 indexed tokenId,
        address indexed buyer,
        uint128 price,
        address indexed paymentToken,
        bool isFromBidding
    );
    event BidAccepted(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed bidder,
        uint128 amount,
        address paymentToken
    );
    event BidRemoved(
        uint256 indexed tokenId,
        address indexed bidder,
        uint128 amount
    );
    event PaymentTokenAdded(address indexed token);
    event PaymentTokenRemoved(address indexed token);
    event ListingTokenChanged(
        uint256 indexed tokenId,
        address indexed oldToken,
        address indexed newToken,
        address caller
    );
    event ListingPriceChanged(
        uint256 indexed tokenId,
        uint128 oldPrice,
        uint128 newPrice,
        address indexed caller
    );
    event EmergencyTokenWithdrawal(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    event PurchaseRequested(
        uint256 indexed tokenId,
        address indexed buyer,
        uint128 offerPrice,
        address indexed paymentToken,
        uint64 confirmationDeadline,
        bool isFromBidding
    );
    event PurchaseRejected(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint128 offerPrice,
        address paymentToken,
        bool isFromBidding
    );
    event PurchaseExpired(
        uint256 indexed tokenId,
        address indexed buyer,
        uint128 offerPrice,
        address indexed paymentToken
    );

    event PaymentProcessed(
        address indexed paymentRecipient,
        address indexed paymentSender,
        uint256 amount,
        uint256 fees,
        address indexed paymentToken,
        address feeCollector
    );

    event BiddingDeactivatedForListing(
        uint256 indexed tokenId,
        address indexed seller
    );

    event BiddingReactivatedForListing(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 biddingActivationCount,
        uint256 maxBiddingActivationCount
    );
    event BidPlaced(
        uint256 indexed tokenId,
        address indexed bidder,
        uint128 amount,
        address paymentToken
    );
    event AllBidsClearedForProperty(
        uint256 indexed tokenId,
        address indexed clearedBy
    );

    event BidPruned(
        uint256 indexed tokenId,
        address indexed bidder,
        uint128 amount,
        string reason
    );
    event MinConfirmationPeriodSet(
        uint256 oldMinConfirmationPeriod,
        uint256 newMinConfirmationPeriod
    );
    event MaxConfirmationPeriodSet(
        uint256 oldMaxConfirmationPeriod,
        uint256 newMaxConfirmationPeriod
    );
    event MaxToggleBiddingReactivationSet(
        uint256 oldMaxToggleBiddingReactivation,
        uint256 newMaxToggleBiddingReactivation
    );

    //Errors
    error ZeroAddress();
    error DirectEthTransferNotAllowed();
    error NotOwnerOfToken(uint256 tokenId, address owner);
    error TokenNotListed(uint256 tokenId);
    error RequestedConfirmationPeriodTooLong(uint256 period, uint256 maxPeriod);
    error RequestedConfirmationPeriodTooShort(
        uint256 period,
        uint256 minPeriod
    );
    error NotKYCVerified(address user);
    error NotAllowedToken(address token);
    error ZeroAmount();
    error HighestBidIsHigherThanListingPrice(
        uint256 tokenId,
        uint128 highestBid,
        uint128 listingPrice
    );
    error NotInPendingSellerConfirmation(
        uint256 tokenId,
        PropertyStatus status
    );
    error PurchaseNonExistent(uint256 tokenId);
    error CallerNotSeller(uint256 tokenId, address caller, address seller);
    error PurchaseConfirmationPeriodExpired(
        uint256 tokenId,
        uint256 confirmationDeadline
    );
    error PurchaseConfirmationPeriodNotExpired(
        uint256 tokenId,
        uint256 confirmationDeadline
    );
    error CallerIsSeller(uint256 tokenId, address caller, address seller);
    error BidTooLow(uint256 bidAmount, uint256 requiredBid);
    error NotATopBidder();
    error CannotWithdrawHighestBid();
    error CannotListPropertyDueToNFTNotApproved(uint256 tokenId);
    error CannotCreatePendingPurchaseDueToInsufficientAllowance(
        address token,
        uint256 settlementPrice,
        uint256 allowance
    );
    error InvalidTopBidIndex(uint256 index, uint256 topIndex);
    error NoBidsForToken(uint256 tokenId);
    error BidHasChanged(
        address expectedBidder,
        address actualBidder,
        uint128 expectedAmount,
        uint128 actualAmount
    );
    error NotEnoughAllowanceOrBalanceToPlaceBid(
        address token,
        uint128 bid,
        uint256 allowance,
        uint256 balance
    );
    error BiddingNotActive(uint256 tokenId);
    error BiddingMustNotBeActive(uint256 tokenId);
    error ListingNotChanged(uint256 tokenId);
    error InvalidToken();
    error EmergencyWithdrawAmountTooHigh();
    error OnlyAdminCanCall();
    error AdminControlMismatch(address passedAdminControl, address onNFT);
    error MaxBiddingReactivationCountReached(uint256 tokenId);
    error CallerNotSellerOrBuyer(
        uint256 tokenId,
        address caller,
        address seller,
        address buyer
    );
    error FeeMismatch(uint256 expectedFee, uint256 baseFee);
    error EmptyTopBid(uint256 tokenId);
    error InvalidNFTCollection(address token);
    error UnexpectedERC721Transfer(address from, uint256 tokenId);
    error BidIsValid(uint256 tokenId, uint256 topBidIndex, address bidder);
    error OnlyTokenWhitelistManagerCanCall();
    error NotNftPropertyManager();
    error OnlyProtocolParamManagerCanCall();
    error MinConfirmationPeriodTooLow(
        uint256 newMinConfirmationPeriod,
        uint256 maxConfirmationPeriod
    );
    error MaxConfirmationPeriodTooLow(
        uint256 newMaxConfirmationPeriod,
        uint256 minConfirmationPeriod
    );
    //Modifiers
    modifier onlyAdminControlAdmin() {
        if (
            !adminControl.hasRole(adminControl.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert OnlyAdminCanCall();
        }
        _;
    }

    modifier onlyNftPropertyManager() {
        if (
            !adminControl.hasRole(
                adminControl.NFT_PROPERTY_MANAGER_ROLE(),
                msg.sender
            )
        ) {
            revert NotNftPropertyManager();
        }
        _;
    }

    modifier onlyProtocolParamManager() {
        if (
            !adminControl.hasRole(
                adminControl.PROTOCOL_PARAM_MANAGER_ROLE(),
                msg.sender
            )
        ) {
            revert OnlyProtocolParamManagerCanCall();
        }
        _;
    }

    modifier onlyTokenWhitelistManager() {
        if (
            !adminControl.hasRole(
                adminControl.TOKEN_WHITELIST_MANAGER_ROLE(),
                msg.sender
            )
        ) {
            revert OnlyTokenWhitelistManagerCanCall();
        }
        _;
    }

    modifier onlyKYCVerified() {
        if (!adminControl.isKYCVerified(msg.sender)) {
            revert NotKYCVerified(msg.sender);
        }
        _;
    }

    modifier onlyAllowedToken(address token) {
        if (!allowedPaymentTokens[token]) {
            revert NotAllowedToken(token);
        }
        _;
    }

    modifier onlyNonZeroAmount(uint256 amount) {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _;
    }

    modifier onlySellerCanCall(uint256 tokenId) {
        PropertyListing storage listing = listings[tokenId];
        if (listing.seller != msg.sender) {
            revert CallerNotSeller(tokenId, msg.sender, listing.seller);
        }
        _;
    }

    //Constructor

    constructor(
        IManageLifePropertyNFT _manageLifePropertyNFT,
        AdminControl _adminControl,
        uint256 _minimumBidIncrement
    ) {
        if (address(_manageLifePropertyNFT) == address(0)) {
            revert ZeroAddress();
        }

        address adminOnNFT = address(_manageLifePropertyNFT.adminController());
        if (adminOnNFT != address(_adminControl)) {
            revert AdminControlMismatch(address(_adminControl), adminOnNFT);
        }

        manageLifePropertyNFT = _manageLifePropertyNFT;
        adminControl = _adminControl;
        minimumBidIncrement = _minimumBidIncrement;
        minConfirmationPeriod = 5 days;
        maxConfirmationPeriod = 14 days;
        maxToggleBiddingReactivation = 5;
    }

    //Receive function

    //We don't want to allow direct eth transfers to the contract
    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }

    //External functions
    function addAllowedToken(address token) external onlyTokenWhitelistManager {
        if (token == address(0)) {
            revert InvalidToken();
        }
        allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token);
    }

    //Only affects new listings, existing listings are not affected.
    function removeAllowedToken(
        address token
    ) external onlyTokenWhitelistManager {
        if (token == address(0)) {
            revert InvalidToken();
        }
        allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token);
    }

    //Step 1: Listing and unlisting
    function listProperty(
        uint256 tokenId,
        uint128 price,
        address paymentToken,
        uint64 confirmationPeriod
    )
        external
        nonReentrant
        onlyKYCVerified
        onlyAllowedToken(paymentToken)
        onlyNonZeroAmount(price)
    {
        if (confirmationPeriod > maxConfirmationPeriod) {
            revert RequestedConfirmationPeriodTooLong(
                confirmationPeriod,
                maxConfirmationPeriod
            );
        }
        if (confirmationPeriod < minConfirmationPeriod) {
            revert RequestedConfirmationPeriodTooShort(
                confirmationPeriod,
                minConfirmationPeriod
            );
        }
        _listPropertyWithConfirmation(
            tokenId,
            price,
            paymentToken,
            confirmationPeriod
        );
    }

    function unlistProperty(
        uint256 tokenId
    ) external onlyKYCVerified onlySellerCanCall(tokenId) nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        listing.status = PropertyStatus.DELISTED;

        manageLifePropertyNFT.safeTransferFrom(
            address(this),
            msg.sender,
            tokenId
        );

        emit PropertyUnlisted(tokenId, msg.sender);
    }

    function updateListingByAdmin(
        uint256 tokenId,
        uint128 newPrice,
        address newPaymentToken
    )
        external
        onlyNonZeroAmount(newPrice)
        onlyAllowedToken(newPaymentToken)
        onlyNftPropertyManager
    {
        _updateListing(tokenId, newPrice, newPaymentToken);
    }

    /**
     * @notice Updates a listing by the seller.
     * @notice Doesn't need reentrnacy, but it's there to prevent cross-function reentrancy.
     */
    function updateListingBySeller(
        uint256 tokenId,
        uint128 newPrice,
        address newPaymentToken
    )
        external
        onlyNonZeroAmount(newPrice)
        onlyAllowedToken(newPaymentToken)
        onlySellerCanCall(tokenId)
        onlyKYCVerified
        nonReentrant
    {
        _updateListing(tokenId, newPrice, newPaymentToken);
    }

    //Step 2: Non-Bidding Purchases, called by buyers that don't want to bid and just buy at listing price.

    //Separate function for accepting the listing price, no bids.
    function purchasePropertyAtListingPrice(
        uint256 tokenId,
        uint256 expectedFee
    ) external nonReentrant onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        uint128 highestBid = listing.highestBid;
        if (highestBid > listing.price) {
            //Can no longer do a purchase at listing price, because there is a higher bid, need to go bid.
            revert HighestBidIsHigherThanListingPrice(
                tokenId,
                highestBid,
                listing.price
            );
        }
        _createPendingPurchase(
            tokenId,
            listing.price,
            listing.paymentToken,
            msg.sender,
            expectedFee
        );
    }

    //Step 3: Purchase confirmations or rejections, and dealing with expired purchases.

    //Perfom full settlement here because both the NFT and tokens are escrowed.
    //Currently this is being used for the listing price purchase.
    function confirmPurchase(
        uint256 tokenId
    ) external nonReentrant onlySellerCanCall(tokenId) onlyKYCVerified {
        (
            PropertyListing storage listing,
            PendingPurchase storage purchase
        ) = _performPendingPurchaseChecks(tokenId);

        //Send the NFT to buyer,  because it's escrowed already.
        _processNFTTransfer(tokenId, purchase.buyer);

        //Send escrowed tokens to seller
        _processPropertyTokenPayment(
            listing.seller,
            purchase.price,
            purchase.paymentToken,
            purchase.fee,
            purchase.feeCollector
        );

        listing.status = PropertyStatus.SOLD;
        delete pendingPurchases[tokenId];

        emit PropertySold(
            tokenId,
            purchase.buyer,
            purchase.price,
            purchase.paymentToken,
            listing.price != purchase.price // if the price is different from listing price, it's from bidding.
        );
    }

    //Rejects a particular purchase, refunds the tokens, but NOT the NFT because it's back in listed state, awaiting a new sale.
    function rejectPurchase(
        uint256 tokenId
    ) external onlySellerCanCall(tokenId) onlyKYCVerified nonReentrant {
        (
            PropertyListing storage listing,
            PendingPurchase storage purchase
        ) = _performPendingPurchaseChecks(tokenId);

        address buyer = purchase.buyer;

        _refundPendingPurchaseTokens(tokenId); //This undoes the escrow of the purchase token.

        emit PurchaseRejected(
            tokenId,
            msg.sender,
            purchase.buyer,
            purchase.price,
            purchase.paymentToken,
            listing.price != purchase.price // if the price is different from listing price, it's from bidding.
        );

        delete pendingPurchases[tokenId]; //Delete the purchase from the pending purchases map.
        listing.status = PropertyStatus.LISTED; //Back to listed state.
        if (listing.price != purchase.price) {
            //if this purchase is from bidding, remove the bid.
            _removeTopBid(tokenId, buyer);
        }
    }

    function pruneInvalidBids(
        uint256 tokenId,
        uint256 topBidIndex,
        address expectedBidder,
        uint128 expectedAmount
    )
        external
        onlySellerCanCall(tokenId)
        onlyKYCVerified
        returns (bool removed)
    {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        if (topBidIndex >= TOP_BIDS_COUNT) {
            revert InvalidTopBidIndex(topBidIndex, TOP_BIDS_COUNT - 1);
        }
        if (listing.highestBidder == address(0)) {
            revert NoBidsForToken(tokenId);
        }

        TopBidCandidate storage topBid = listing.topBids[topBidIndex];
        if (topBid.bidder == address(0) || topBid.amount == 0) {
            revert EmptyTopBid(tokenId);
        }

        // Front-run protection
        if (
            topBid.bidder != expectedBidder || topBid.amount != expectedAmount
        ) {
            revert BidHasChanged(
                expectedBidder,
                topBid.bidder,
                expectedAmount,
                topBid.amount
            );
        }

        address bidder = topBid.bidder;
        uint128 amount = topBid.amount;
        IERC20 paymentToken = IERC20(listing.paymentToken);

        uint256 allowance = paymentToken.allowance(bidder, address(this));
        if (allowance < amount) {
            _removeTopBid(tokenId, bidder);
            emit BidPruned(tokenId, bidder, amount, "low allowance");
            return true;
        }

        uint256 balance = paymentToken.balanceOf(bidder);
        if (balance < amount) {
            _removeTopBid(tokenId, bidder);
            emit BidPruned(tokenId, bidder, amount, "low balance");
            return true;
        }

        revert BidIsValid(tokenId, topBidIndex, bidder);
    }

    //Step 4: Bidding

    /**
     * @notice Places a bid on a listed property, ensuring only one bid per user.
     * @notice Doesn't need reentrnacy, but it's there to prevent cross-function reentrancy.
     * @dev This function uses a "remove and re-insert" pattern to handle existing
     *      bidders who want to increase their bid. This ensures the `topBids`
     *      array remains sorted and contains unique bidders.
     *
     *      Graphical Example:
     *      Assume TOP_BIDS_COUNT is 4 and Charlie wants to increase his bid.
     *
     *      Initial `topBids` State:
     *      [0]: { bidder: Alice, amount: 100 }
     *      [1]: { bidder: Charlie, amount: 95 }
     *      [2]: { bidder: Bob, amount: 90 }
     *      [3]: { bidder: David, amount: 85 }
     *
     *      Charlie calls `placeBid2` with a new amount of 105.
     *
     *      1. Remove Old Bid: The first loop finds Charlie's old bid at index 1
     *         and removes it by shifting lower bids up.
     *
     *      State after removal:
     *      [0]: { bidder: Alice, amount: 100 }
     *      [1]: { bidder: Bob, amount: 90 }
     *      [2]: { bidder: David, amount: 85 }
     *      [3]: (empty)
     *
     *      2. Insert New Bid: The second loop shifts all bids down to make
     *         space at the top for Charlie's new, higher bid.
     *
     *      Final `topBids` State:
     *      [0]: { bidder: Charlie, amount: 105 }
     *      [1]: { bidder: Alice, amount: 100 }
     *      [2]: { bidder: Bob, amount: 90 }
     *      [3]: { bidder: David, amount: 85 }
     */
    function placeBid(
        uint256 tokenId,
        uint128 bidAmount
    ) external onlyKYCVerified onlyNonZeroAmount(bidAmount) nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        IERC20 paymentToken = IERC20(listing.paymentToken);

        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        if (!listing.biddingActive) {
            revert BiddingNotActive(tokenId);
        }

        if (listing.seller == msg.sender) {
            revert CallerIsSeller(tokenId, msg.sender, listing.seller);
        }
        // Check that the contract is allowed to transfer tokens on behalf of the buyer
        uint256 allowance = paymentToken.allowance(msg.sender, address(this));
        uint256 balance = paymentToken.balanceOf(msg.sender);
        if (allowance < bidAmount || balance < bidAmount) {
            revert NotEnoughAllowanceOrBalanceToPlaceBid(
                listing.paymentToken,
                bidAmount,
                allowance,
                balance
            );
        }

        uint256 requiredBid = _getRequiredBid(listing);

        if (uint256(bidAmount) < requiredBid) {
            revert BidTooLow(uint256(bidAmount), requiredBid);
        }

        // --- Remove and Re-insert Logic ---

        // Step 1: Find and remove the user's previous bid, if it exists.
        uint8 bidIndex = TOP_BIDS_COUNT; // Use count as a sentinel for "not found"
        for (uint8 i = 0; i < TOP_BIDS_COUNT; i++) {
            if (listing.topBids[i].bidder == msg.sender) {
                bidIndex = i;
                break;
            }
        }

        // If a previous bid was found, remove it by shifting lower bids up.
        if (bidIndex < TOP_BIDS_COUNT) {
            for (uint8 i = bidIndex; i < TOP_BIDS_COUNT - 1; i++) {
                listing.topBids[i] = listing.topBids[i + 1];
            }
            // Clear the last slot, which is now a duplicate or empty.
            delete listing.topBids[TOP_BIDS_COUNT - 1];
        }

        // Step 2: Insert the new bid at the top.
        // Shift all existing bids down to make space.
        for (uint8 i = TOP_BIDS_COUNT - 1; i > 0; --i) {
            listing.topBids[i] = listing.topBids[i - 1];
        }

        // Assign the new bid's data to the top slot.
        listing.topBids[0].bidder = msg.sender;
        listing.topBids[0].amount = bidAmount;
        listing.topBids[0].bidTimestamp = uint64(block.timestamp);

        // Update the listing's highest bid information.
        listing.highestBidder = msg.sender;
        listing.highestBid = bidAmount;

        emit BidPlaced(tokenId, msg.sender, bidAmount, listing.paymentToken);
    }

    /**
     * @notice Withdraws a bid from a listed property.
     * @notice Doesn't need reentrnacy, but it's there to prevent cross-function reentrancy.
     */
    function withdrawBid(
        uint256 tokenId
    ) external nonReentrant onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        if (listing.highestBidder == msg.sender && listing.highestBid > 0) {
            revert CannotWithdrawHighestBid();
        }

        if (!_removeTopBid(tokenId, msg.sender)) {
            revert NotATopBidder();
        }
    }

    //Note: This mechanism was implemented to prevent griefing/DOS attacks against the acceptBid function.
    //However, this opens the doors to the seller changing the status to fish for better bids, which could frustrate bidders
    //This is a good tradeoff, but it's importanat to recognize that it gives the seller more power.
    //I added a max count of re-activations to prevent abuse, and have the seller finally have to accept a bid.
    //Could be made more fair by having the bid status depend on time.
    /**
     * @notice Toggles the bidding active status for a listed property.
     * @notice Doesn't need reentrnacy, but it's there to prevent cross-function reentrancy.
     */
    function toggleBiddingActiveStatus(
        uint256 tokenId
    )
        external
        onlySellerCanCall(tokenId)
        nonReentrant
        onlyKYCVerified
        returns (bool)
    {
        PropertyListing storage listing = listings[tokenId];
        if (listings[tokenId].status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        if (listing.biddingActive) {
            listing.biddingActive = false;
            emit BiddingDeactivatedForListing(tokenId, msg.sender);
        } else {
            if (
                listing.biddingActivationCount >= maxToggleBiddingReactivation
            ) {
                revert MaxBiddingReactivationCountReached(tokenId);
            }
            listing.biddingActive = true;
            listing.biddingActivationCount++;
            emit BiddingReactivatedForListing(
                tokenId,
                msg.sender,
                listing.biddingActivationCount,
                maxToggleBiddingReactivation
            );
        }
        return listing.biddingActive;
    }

    //seller calls
    function acceptBid(
        uint256 tokenId,
        uint256 topBidIndex,
        address expectedBidder,
        uint128 expectedAmount,
        uint256 expectedFee
    ) external nonReentrant onlySellerCanCall(tokenId) onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        if (listing.biddingActive) {
            revert BiddingMustNotBeActive(tokenId);
        }
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        if (topBidIndex >= TOP_BIDS_COUNT) {
            revert InvalidTopBidIndex(topBidIndex, TOP_BIDS_COUNT - 1);
        }

        if (listing.highestBidder == address(0)) {
            revert NoBidsForToken(tokenId);
        }

        TopBidCandidate storage topBid = listing.topBids[topBidIndex];

        if (topBid.bidder == address(0) && topBid.amount == 0) {
            revert EmptyTopBid(tokenId);
        }

        //Front run protection
        if (
            topBid.bidder != expectedBidder || topBid.amount != expectedAmount
        ) {
            revert BidHasChanged(
                expectedBidder,
                topBid.bidder,
                expectedAmount,
                topBid.amount
            );
        }

        _createPendingPurchase(
            tokenId,
            topBid.amount,
            listing.paymentToken,
            topBid.bidder,
            expectedFee
        );
        listing.biddingActive = false; //Not necessary, but correct.
        emit BidAccepted(
            tokenId,
            listing.seller,
            topBid.bidder,
            topBid.amount,
            listing.paymentToken
        );
    }

    //An expired purchase is a purchase that has not been confirmed or rejected within the confirmation period.
    //Puts the token back into listed state, where bids can be placed again.
    function cancelExpiredPurchase(
        uint256 tokenId
    ) external nonReentrant onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        PendingPurchase storage purchase = pendingPurchases[tokenId];

        if (listing.seller != msg.sender && purchase.buyer != msg.sender) {
            revert CallerNotSellerOrBuyer(
                tokenId,
                msg.sender,
                listing.seller,
                purchase.buyer
            );
        }

        if (listing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION) {
            revert NotInPendingSellerConfirmation(tokenId, listing.status);
        }
        if (purchase.paymentToken == address(0)) {
            revert PurchaseNonExistent(tokenId);
        }
        if (block.timestamp <= purchase.confirmationDeadline) {
            revert PurchaseConfirmationPeriodNotExpired(
                tokenId,
                purchase.confirmationDeadline
            );
        }

        if (listing.price != purchase.price) {
            //if this purchase is from bidding, remove the bid.
            _removeTopBid(tokenId, purchase.buyer);
        }

        _refundPendingPurchaseTokens(tokenId); //Undo escrow of the purchase token.

        listing.status = PropertyStatus.LISTED; //Back to listed state.

        emit PurchaseExpired(
            tokenId,
            purchase.buyer,
            purchase.price,
            purchase.paymentToken
        );
        delete pendingPurchases[tokenId]; //Delete the purchase from the pending purchases map.
    }

    //Configuration functions
    function setMinConfirmationPeriod(
        uint256 newMinConfirmationPeriod
    ) external onlyProtocolParamManager {
        if (newMinConfirmationPeriod == 0) {
            revert ZeroAmount();
        }
        if (newMinConfirmationPeriod > maxConfirmationPeriod) {
            revert MinConfirmationPeriodTooLow(
                newMinConfirmationPeriod,
                maxConfirmationPeriod
            );
        }
        uint256 oldMinConfirmationPeriod = minConfirmationPeriod;
        minConfirmationPeriod = newMinConfirmationPeriod;
        emit MinConfirmationPeriodSet(
            oldMinConfirmationPeriod,
            newMinConfirmationPeriod
        );
    }

    function setMaxConfirmationPeriod(
        uint256 newMaxConfirmationPeriod
    ) external onlyProtocolParamManager {
        if (newMaxConfirmationPeriod < minConfirmationPeriod) {
            revert MaxConfirmationPeriodTooLow(
                newMaxConfirmationPeriod,
                minConfirmationPeriod
            );
        }
        uint256 oldMaxConfirmationPeriod = maxConfirmationPeriod;
        maxConfirmationPeriod = newMaxConfirmationPeriod;
        emit MaxConfirmationPeriodSet(
            oldMaxConfirmationPeriod,
            newMaxConfirmationPeriod
        );
    }

    function setMaxToggleBiddingReactivation(
        uint256 newMaxToggleBiddingReactivation
    ) external onlyProtocolParamManager {
        if (newMaxToggleBiddingReactivation == 0) {
            revert ZeroAmount();
        }
        uint256 oldMaxToggleBiddingReactivation = maxToggleBiddingReactivation;
        maxToggleBiddingReactivation = newMaxToggleBiddingReactivation;
        emit MaxToggleBiddingReactivationSet(
            oldMaxToggleBiddingReactivation,
            newMaxToggleBiddingReactivation
        );
    }

    //Admin Emergency functions
    //TODO: add time lock to this.
    function emergencyWithdrawToken(
        address token,
        uint256 amount,
        address recipient
    ) external onlyAdminControlAdmin nonReentrant {
        if (token == address(0)) {
            revert InvalidToken();
        }
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        IERC20 tokenContract = IERC20(token);
        if (amount > tokenContract.balanceOf(address(this))) {
            revert EmergencyWithdrawAmountTooHigh();
        }

        tokenContract.safeTransfer(recipient, amount);

        emit EmergencyTokenWithdrawal(token, recipient, amount);
    }

    //View functions

    function getListingDetails(
        uint256 tokenId
    )
        external
        view
        returns (
            address seller,
            uint128 price,
            address paymentToken,
            PropertyStatus status,
            uint64 listTimestamp,
            uint64 confirmationPeriod,
            bool biddingActive,
            address highestBidder,
            uint128 highestBid
        )
    {
        PropertyListing storage listing = listings[tokenId];
        return (
            listing.seller,
            listing.price,
            listing.paymentToken,
            listing.status,
            listing.listTimestamp,
            listing.confirmationPeriod,
            listing.biddingActive,
            listing.highestBidder,
            listing.highestBid
        );
    }

    function getTopBidsForListing(
        uint256 tokenId
    ) external view returns (TopBidCandidate[TOP_BIDS_COUNT] memory) {
        PropertyListing storage listing = listings[tokenId];
        return listing.topBids;
    }

    //ERC721Receiver interface

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) public override(ERC721Holder) returns (bytes4) {
        // Only accept the managed collection
        if (msg.sender != address(manageLifePropertyNFT)) {
            revert InvalidNFTCollection(msg.sender);
        }

        // Only accept transfers that are part of the controlled listing flow:
        // _listPropertyWithConfirmation sets these *before* safeTransferFrom.
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED || listing.seller != from) {
            revert UnexpectedERC721Transfer(from, tokenId);
        }

        return this.onERC721Received.selector;
    }

    //Internal Functions

    function _listPropertyWithConfirmation(
        uint256 tokenId,
        uint128 price,
        address paymentToken,
        uint64 period
    ) internal {
        address currentOwner = manageLifePropertyNFT.ownerOf(tokenId);
        if (currentOwner != msg.sender) {
            revert NotOwnerOfToken(tokenId, currentOwner);
        }
        PropertyListing storage existingListing = listings[tokenId];

        //Should never happen, that's why it's an assert. The NFT is escrowed, so it cannot be listed twice.
        assert(
            existingListing.status != PropertyStatus.LISTED &&
                existingListing.status !=
                PropertyStatus.PENDING_SELLER_CONFIRMATION
        );

        // A check for a previous listing by a different owner is not necessary.
        // For a new owner to list the NFT, they must hold it, which means it cannot be
        // in escrow from a previous `LISTED` or `PENDING_SELLER_CONFIRMATION` state.
        // Any previous listing data from a different owner is therefore considered stale
        // and will be safely overwritten by the new listing.

        // Similarly, checks to prevent the current owner from re-listing an already active
        // listing are also redundant. If the listing were active, the contract would hold
        // the NFT, and the initial ownership check on this function would have failed.
        // Therefore, we can proceed directly to creating the new listing.

        //Fresh lising for token
        delete listings[tokenId]; //Delete old listing data
        PropertyListing storage listing = listings[tokenId];
        listing.tokenId = tokenId;
        listing.seller = msg.sender;
        listing.price = price;
        listing.paymentToken = paymentToken;
        listing.status = PropertyStatus.LISTED;
        listing.listTimestamp = uint64(block.timestamp);
        listing.lastRenewed = uint64(block.timestamp);
        listing.confirmationPeriod = period;
        listing.biddingActive = true;

        if (
            !manageLifePropertyNFT.isApprovedForAll(
                msg.sender,
                address(this)
            ) && manageLifePropertyNFT.getApproved(tokenId) != address(this)
        ) {
            revert CannotListPropertyDueToNFTNotApproved(tokenId);
        }

        // Move the NFT to this contract (escrow) when listing
        manageLifePropertyNFT.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );

        emit NewListing(tokenId, msg.sender, price, paymentToken);
    }

    function _createPendingPurchase(
        uint256 tokenId,
        uint128 settlementPrice,
        address paymentToken,
        address buyer,
        uint256 expectedFee
    ) internal {
        PropertyListing storage listing = listings[tokenId];
        IERC20 token = IERC20(paymentToken);
        listing.status = PropertyStatus.PENDING_SELLER_CONFIRMATION; //Now entering the escrow phase. We can safely escrow the tokens because this is called by the buyer.
        uint256 deadline = block.timestamp + listing.confirmationPeriod;
        (uint256 baseFee, , address feeCollector) = adminControl.feeConfig(); //Fee should be obtaiend at this stage to prevent malicious changing at settlement time.

        if (baseFee != expectedFee) {
            revert FeeMismatch(expectedFee, baseFee);
        }

        pendingPurchases[tokenId] = PendingPurchase({
            tokenId: tokenId,
            buyer: buyer,
            price: settlementPrice,
            paymentToken: paymentToken,
            purchaseTimestamp: uint64(block.timestamp),
            confirmationDeadline: uint64(deadline),
            fee: uint64(baseFee),
            feeCollector: feeCollector
        });

        // Check that the contract is allowed to transfer tokens on behalf of the buyer
        uint256 allowance = token.allowance(buyer, address(this));
        if (allowance < settlementPrice) {
            revert CannotCreatePendingPurchaseDueToInsufficientAllowance(
                address(token),
                settlementPrice,
                allowance
            );
        }

        token.safeTransferFrom(buyer, address(this), settlementPrice); //Buyer sends tokens to escrow.

        emit PurchaseRequested(
            tokenId,
            buyer,
            settlementPrice,
            paymentToken,
            uint64(deadline),
            listing.price != settlementPrice // if the price is different from listing price, it's from bidding.
        );
    }

    function _performPendingPurchaseChecks(
        uint256 tokenId
    )
        internal
        view
        returns (
            PropertyListing storage listing,
            PendingPurchase storage purchase
        )
    {
        listing = listings[tokenId];
        purchase = pendingPurchases[tokenId];

        //Check if purchase object exists
        if (purchase.paymentToken == address(0)) {
            revert PurchaseNonExistent(tokenId);
        }

        //Listing needs to be in pending seller confirmation.
        if (listing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION) {
            revert NotInPendingSellerConfirmation(tokenId, listing.status);
        }

        //Caller needs to be the owner of the token.
        //Should never happen, that's why it's an assert.
        address currentOwner = manageLifePropertyNFT.ownerOf(tokenId);
        assert(currentOwner == address(this));

        if (block.timestamp > purchase.confirmationDeadline) {
            revert PurchaseConfirmationPeriodExpired(
                tokenId,
                purchase.confirmationDeadline
            );
        }
        return (listing, purchase);
    }

    function _refundPendingPurchaseTokens(uint256 tokenId) internal {
        PendingPurchase storage purchase = pendingPurchases[tokenId];
        IERC20 token = IERC20(purchase.paymentToken);
        token.safeTransfer(purchase.buyer, purchase.price);
    }

    function _removeTopBid(
        uint256 tokenId,
        address bidder
    ) internal returns (bool) {
        PropertyListing storage listing = listings[tokenId];

        uint8 bidIndex = TOP_BIDS_COUNT;
        uint128 amount = 0;
        for (uint8 i = 0; i < TOP_BIDS_COUNT; i++) {
            if (listing.topBids[i].bidder == bidder) {
                bidIndex = i;
                amount = listing.topBids[i].amount;
                break;
            }
        }

        if (bidIndex < TOP_BIDS_COUNT) {
            for (uint8 i = bidIndex; i < TOP_BIDS_COUNT - 1; i++) {
                listing.topBids[i] = listing.topBids[i + 1];
            }
            delete listing.topBids[TOP_BIDS_COUNT - 1];

            if (bidIndex == 0) {
                listing.highestBidder = listing.topBids[0].bidder;
                listing.highestBid = listing.topBids[0].amount;
            }
            emit BidRemoved(tokenId, bidder, amount);
            return true;
        }
        return false;
    }

    //All this does at this point is send the fees to the fee collector and the net value to the seller.
    function _processPropertyTokenPayment(
        address tokenRecipient,
        uint128 amount,
        address paymentToken,
        uint64 fee,
        address feeCollector
    ) internal {
        IERC20 token = IERC20(paymentToken);
        uint256 fees = (amount * fee) / PERCENTAGE_BASE;
        uint256 netValue = amount - fees;

        token.safeTransfer(tokenRecipient, netValue);
        token.safeTransfer(feeCollector, fees);
        emit PaymentProcessed(
            tokenRecipient,
            address(this),
            amount,
            fees,
            paymentToken,
            feeCollector
        );
    }

    function _processNFTTransfer(uint256 tokenId, address buyer) internal {
        //NFT is escrowed, just send to to the buyer.
        // Token is escrowed, just send it from escrow to the buyer
        manageLifePropertyNFT.safeTransferFrom(
            address(this),
            buyer,
            tokenId,
            ""
        );
    }

    function _updateListing(
        uint256 tokenId,
        uint128 newPrice,
        address newPaymentToken
    ) internal {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        if (
            listing.paymentToken == newPaymentToken && listing.price == newPrice
        ) {
            revert ListingNotChanged(tokenId);
        }
        //Clear bidding info, they are no longer valid, there are any.
        if (listing.highestBidder != address(0)) {
            delete listing.highestBidder;
            delete listing.highestBid;
            delete listing.topBids;
            emit AllBidsClearedForProperty(tokenId, msg.sender);
        }

        if (listing.paymentToken != newPaymentToken) {
            emit ListingTokenChanged(
                tokenId,
                listing.paymentToken,
                newPaymentToken,
                msg.sender
            );
            listing.paymentToken = newPaymentToken;
        }
        if (listing.price != newPrice) {
            emit ListingPriceChanged(
                tokenId,
                listing.price,
                newPrice,
                msg.sender
            );
            listing.price = newPrice;
        }

        listing.lastRenewed = uint64(block.timestamp);
    }

    function _getRequiredBid(
        PropertyListing storage listing
    ) internal view returns (uint256) {
        if (listing.highestBid == 0) {
            // First bid must exceed the listing price by at least 1 unit
            return listing.price + 1;
        }
        uint256 increment = (uint256(listing.highestBid) *
            minimumBidIncrement) / PERCENTAGE_BASE;
        if (increment == 0) {
            increment = 1;
        }
        return uint256(listing.highestBid) + increment;
    }
}
