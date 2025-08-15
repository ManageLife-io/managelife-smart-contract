// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AdminControl} from "../governance/AdminControl.sol";
import {PaymentProcessor} from "../libraries/PaymentProcessor.sol"; //TODO: merge this library into this contract - only place it's used.
import {IManageLifePropertyNFT} from "../interfaces/IManageLifePropertyNFT.sol";


contract PropertyMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    //Constants and immutable variables
    uint8 private constant TOP_BIDS_COUNT = 10;
    uint256 private constant PERCENTAGE_BASE = 10000;
    //Maybe these should be configurable.
    uint256 public immutable MIN_CONFIRMATION_PERIOD = 5 days;
    uint256 public immutable MAX_CONFIRMATION_PERIOD = 14 days;

    //Data Structures
    struct TopBidCandidate {
        address bidder;
        uint256 amount;
        uint256 bidTimestamp;
    }

    //TODO: struct packing
    struct PropertyListing {
        //Maybe can add min bid to make more flexible later
        uint256 tokenId;
        address seller;
        uint256 price;
        address paymentToken;
        PropertyStatus status;
        uint256 listTimestamp;
        uint256 lastRenewed;
        uint256 confirmationPeriod;
        // global bidding state for the listing/auction
        bool biddingActive;
        address highestBidder;
        uint256 highestBid;
        TopBidCandidate[TOP_BIDS_COUNT] topBids;
    }

    struct PendingPurchase {
        uint256 tokenId;
        address buyer;
        uint256 price;
        address paymentToken;
        uint256 purchaseTimestamp;
        uint256 confirmationDeadline;
        // escrow
        bool fundsDeposited;
    }

    enum PropertyStatus {
        LISTED,
        SOLD,
        DELISTED,
        PENDING_SELLER_CONFIRMATION //Also used for escrow period.
    }

    //State Variables

    uint256 public minimumBidIncrement; // e.g., 50 = 0.5%, 100 = 1%
    IManageLifePropertyNFT public immutable manageLifePropertyNFT;
    mapping(address => bool) public allowedPaymentTokens;
    AdminControl public adminControl;
    mapping(uint256 => PropertyListing) public listings;
    mapping(uint256 => PendingPurchase) public pendingPurchases;

    //Events
    event NewListing(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        address paymentToken
    );
    event PropertyUnlisted(uint256 indexed tokenId, address indexed seller);
    event PropertySold(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 price,
        address indexed paymentToken,
        bool isFromBidding
    );
    event BidAccepted(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed bidder,
        uint256 amount,
        address indexedpaymentToken
    );
    event BidRemoved(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount
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
        uint256 oldPrice,
        uint256 newPrice,
        address indexed caller
    );
    event EmergencyTokenWithdrawal(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    event CompetitivePurchase(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 purchasePrice,
        uint256 highestBidOutbid,
        address indexed paymentToken
    );
    event PurchaseRequested(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 offerPrice,
        address indexed paymentToken,
        uint256 confirmationDeadline,
        bool isFromBidding
    );
    event PurchaseRejected(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 offerPrice,
        address paymentToken,
        bool isFromBidding
    );
    event PurchaseExpired(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 offerPrice,
        address indexed paymentToken
    );
    event BiddingActiveStatusChanged(
        uint256 indexed tokenId,
        bool biddingActive,
        address indexed seller
    );
    event BidPlaced(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount,
        address paymentToken
    );
    event AllBidsClearedForProperty(
        uint256 indexed tokenId,
        address indexed clearedBy
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
        uint256 highestBid,
        uint256 listingPrice
    );
    error OfferPriceTooLow(
        uint256 tokenId,
        uint256 offerPrice,
        uint256 listingPrice,
        uint256 highestBid
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
    error CannotConfirmPurchaseDueToNFTNotApproved();
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
        uint256 expectedAmount,
        uint256 actualAmount
    );
    error NotEnoughAllowanceOrBalanceToPlaceBid(
        address token,
        uint256 bid,
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

    //Modifiers
    modifier onlyAdminControlAdmin() {
        if (
            !adminControl.hasRole(adminControl.DEFAULT_ADMIN_ROLE(), msg.sender)
        ) {
            revert OnlyAdminCanCall();
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
    }

    //Receive function

    //We don't want to allow direct eth transfers to the contract
    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }

    //External functions
    function addAllowedToken(address token) external onlyAdminControlAdmin {
        if (token == address(0)) {
            revert InvalidToken();
        }
        allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token);
    }

    //Only affects new listings, existing listings are not affected.
    function removeAllowedToken(address token) external onlyAdminControlAdmin {
        if (token == address(0)) {
            revert InvalidToken();
        }
        allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token);
    }

    //Step 1: Listing and unlisting
    function listProperty(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 confirmationPeriod
    )
        external
        nonReentrant
        onlyKYCVerified
        onlyAllowedToken(paymentToken)
        onlyNonZeroAmount(price)
    {
        if (confirmationPeriod > MAX_CONFIRMATION_PERIOD) {
            revert RequestedConfirmationPeriodTooLong(
                confirmationPeriod,
                MAX_CONFIRMATION_PERIOD
            );
        }
        if (confirmationPeriod < MIN_CONFIRMATION_PERIOD) {
            revert RequestedConfirmationPeriodTooShort(
                confirmationPeriod,
                MIN_CONFIRMATION_PERIOD
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
    ) external onlySellerCanCall(tokenId) {
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
        uint256 newPrice,
        address newPaymentToken
    )
        external
        onlyNonZeroAmount(newPrice)
        onlyAllowedToken(newPaymentToken)
        onlyAdminControlAdmin
    {
        _updateListing(tokenId, newPrice, newPaymentToken);
    }

    function updateListingBySeller(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    )
        external
        onlyNonZeroAmount(newPrice)
        onlyAllowedToken(newPaymentToken)
        onlySellerCanCall(tokenId)
    {
        _updateListing(tokenId, newPrice, newPaymentToken);
    }

    //Step 2: Non-Bidding Purchases, called by buyers that don't want to bid and just buy at listing price.

    //Separate function for accepting the listing price, no bids.
    function purchasePropertyAtListingPrice(
        uint256 tokenId
    ) external nonReentrant onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        uint256 highestBid = listing.highestBid;
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
            msg.sender
        );
    }

    //Step 3: Purchase confirmations or rejections, and dealing with expired purchases.

    //Perfom full settlement here because both the NFT and tokens are escrowed.
    //Currently this is being used for the listing price purchase.
    function confirmPurchase(
        uint256 tokenId
    ) external nonReentrant onlySellerCanCall(tokenId) {
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
            purchase.paymentToken
        );

        listing.status = PropertyStatus.SOLD;

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
    ) external onlySellerCanCall(tokenId) nonReentrant {
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

    //Step 4: Bidding

    /**
     * @notice Places a bid on a listed property, ensuring only one bid per user.
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
        uint256 bidAmount
    ) external onlyKYCVerified onlyNonZeroAmount(bidAmount) {
        PropertyListing storage listing = listings[tokenId];
        IERC20 paymentToken = IERC20(listing.paymentToken);

        if (!listing.biddingActive) {
            revert BiddingNotActive(tokenId);
        }

        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        address currentOwner = manageLifePropertyNFT.ownerOf(tokenId);
        if (currentOwner == msg.sender) {
            revert CallerIsSeller(tokenId, msg.sender, currentOwner);
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
        listing.topBids[0].bidTimestamp = block.timestamp;

        // Update the listing's highest bid information.
        listing.highestBidder = msg.sender;
        listing.highestBid = bidAmount;

        emit BidPlaced(tokenId, msg.sender, bidAmount, listing.paymentToken);
    }

    function withdrawBid(uint256 tokenId) external {
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
    //Could be made more fair by having the bid status change only be one way, or making it time based.
    function changeBiddingActiveStatus(
        uint256 tokenId,
        bool biddingActive
    ) external onlySellerCanCall(tokenId) {
        if (listings[tokenId].status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        listings[tokenId].biddingActive = biddingActive;
        emit BiddingActiveStatusChanged(tokenId, biddingActive, msg.sender);
    }

    //seller calls
    function acceptBid(
        uint256 tokenId,
        uint256 topBidIndex,
        address expectedBidder,
        uint256 expectedAmount
    ) external nonReentrant onlySellerCanCall(tokenId) {
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

        TopBidCandidate storage bid = listing.topBids[topBidIndex];

        //Front run protection
        if (bid.bidder != expectedBidder || bid.amount != expectedAmount) {
            revert BidHasChanged(
                expectedBidder,
                bid.bidder,
                expectedAmount,
                bid.amount
            );
        }

        _createPendingPurchase(
            tokenId,
            bid.amount,
            listing.paymentToken,
            bid.bidder
        );
        listing.biddingActive = false; //Not necessary, but correct.
        emit BidAccepted(
            tokenId,
            listing.seller,
            bid.bidder,
            bid.amount,
            listing.paymentToken
        );
    }

    //An expired purchase is a purchase that has not been confirmed or rejected within the confirmation period.
    //Puts the token back into listed state, where bids can be placed again.
    function cancelExpiredPurchase(uint256 tokenId) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        PendingPurchase storage purchase = pendingPurchases[tokenId];
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

    //Admin Emergency functions
    function emergencyWithdrawToken(
        address token,
        uint256 amount,
        address recipient
    ) external onlyAdminControlAdmin {
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

    //Internal Functions

    //TODO: refactor this into listProperty if we determine we don't need another way to list properties.
    function _listPropertyWithConfirmation(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 period
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
        listing.listTimestamp = block.timestamp;
        listing.lastRenewed = block.timestamp;
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
        uint256 settlementPrice,
        address paymentToken,
        address buyer
    ) internal {
        PropertyListing storage listing = listings[tokenId];
        IERC20 token = IERC20(paymentToken);
        listing.status = PropertyStatus.PENDING_SELLER_CONFIRMATION; //Now entering the escrow phase. We can safely escrow the tokens because this is called by the buyer.
        uint256 deadline = block.timestamp + listing.confirmationPeriod;

        pendingPurchases[tokenId] = PendingPurchase({
            tokenId: tokenId,
            buyer: buyer,
            price: settlementPrice,
            paymentToken: paymentToken,
            purchaseTimestamp: block.timestamp,
            confirmationDeadline: deadline,
            fundsDeposited: true
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
            deadline,
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
        uint256 amount = 0;
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
        uint256 amount,
        address paymentToken
    ) internal {
        (uint256 baseFee, , address feeCollector) = adminControl.feeConfig();
        PaymentProcessor.PaymentConfig memory config = PaymentProcessor
            .PaymentConfig({
                baseFee: baseFee,
                feeCollector: feeCollector,
                percentageBase: PERCENTAGE_BASE
            });

        PaymentProcessor.processPayment(
            config,
            tokenRecipient,
            amount,
            paymentToken
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

    //Admin functions TODO: come back to this.

    function _updateListing(
        uint256 tokenId,
        uint256 newPrice,
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

        listing.lastRenewed = block.timestamp;
    }

    function getListingDetails(
        uint256 tokenId
    )
        external
        view
        returns (
            address seller,
            uint256 price,
            address paymentToken,
            PropertyStatus status,
            uint256 listTimestamp,
            uint256 confirmationPeriod,
            bool biddingActive,
            address highestBidder,
            uint256 highestBid
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
