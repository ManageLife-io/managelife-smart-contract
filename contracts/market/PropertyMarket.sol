// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AdminControl} from "../governance/AdminControl.sol";
import {PaymentProcessor} from "../libraries/PaymentProcessor.sol";
import {ErrorCodes} from "../libraries/ErrorCodes.sol";

contract PropertyMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    constructor(IERC721 _manageLifePropertyNFT, AdminControl _adminControl) {
        //TODO: Check that the admin control is the same as the one in the manage life property nft
        if (address(_manageLifePropertyNFT) == address(0)) {
            revert ZeroAddress();
        }
        manageLifePropertyNFT = _manageLifePropertyNFT;
        adminControl = _adminControl;
    }

    uint8 private constant TOP_BIDS_COUNT = 10;

    uint256 public constant PERCENTAGE_BASE = 10000;

    enum PropertyStatus {
        LISTED,
        SOLD,
        DELISTED, //I don't think this used anywhere.
        PENDING_SELLER_CONFIRMATION //Also used for escrow period.
    }

    error ZeroAddress();
    error DirectEthTransferNotAllowed();
    error NotOwnerOfToken(uint256 tokenId, address owner);
    error TokenAlreadyListed(
        uint256 tokenId,
        address seller,
        uint256 price,
        address paymentToken
    );
    error TokenNotListed(uint256 tokenId);
    error TokenSaleInProgress(
        uint256 tokenId,
        address seller,
        uint256 price,
        address paymentToken
    );
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
    error SellerNotOwnerOfToken(uint256 tokenId, address seller, address owner);
    error PurchaseConfirmationPeriodExpired(
        uint256 tokenId,
        uint256 confirmationDeadline
    );
    error PurchaseConfirmationPeriodNotExpired(
        uint256 tokenId,
        uint256 confirmationDeadline
    );
    error CallerIsSeller(uint256 tokenId, address caller, address seller);
    error BidLowerThanListingPrice(
        address bidder,
        uint256 tokenId,
        uint256 bidAmount,
        uint256 listingPrice
    );
    error BidTooLow(uint256 bidAmount, uint256 requiredBid);
    error NotABidder();
    error CannotWithdrawHighestBid();
    error CannotListPropertyDueToNFTNotApproved(uint256 tokenId);
    error CannotConfirmPurchaseDueToNFTNotApproved();
    error CannotCreatePendingPurchaseDueToInsufficientAllowance(
        address token,
        uint256 settlementPrice,
        uint256 allowance
    );

    struct Bid {
        uint256 tokenId;
        address bidder;
        uint256 amount;
        address paymentToken;
        uint256 bidTimestamp;
        bool isActive;
    }

    struct Bid2 {
        address paymentToken;
        address bidder;
        uint256 amount;
        uint256 bidTimestamp;
    }

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
        address highestBidder;
        uint256 highestBid;
        Bid[TOP_BIDS_COUNT] topBids;
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

    //Maybe these should be configurable.
    uint256 public immutable MIN_CONFIRMATION_PERIOD = 5 days;
    uint256 public immutable MAX_CONFIRMATION_PERIOD = 14 days;

    IERC721 public immutable manageLifePropertyNFT;
    mapping(address => bool) public allowedPaymentTokens;
    AdminControl public adminControl;

    mapping(uint256 => PropertyListing) public listings;
    mapping(uint256 => PendingPurchase) public pendingPurchases;

    mapping(uint256 => Bid[]) public bidsForToken;
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
    event PaymentTokenAdded(address indexed token);
    event PaymentTokenRemoved(address indexed token);
    event ListingPriceChanged(uint256 indexed tokenId, uint256 newPrice);

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

    //Helper Functions
    function isTokenAllowed(address token) internal view returns (bool) {
        return allowedPaymentTokens[token];
    }

    function addAllowedToken(address token) external onlyAdminControlAdmin {
        require(token != address(0), ErrorCodes.E001);
        allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token);
    }

    function removeAllowedToken(address token) external onlyAdminControlAdmin {
        require(token != address(0), ErrorCodes.E001);
        allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token);
    }

    //Step 1: Listing
    /* //Marking for deprecation because I beleive a lising/start of auctiion should always have a confirmation period.
    function listProperty(
        uint256 tokenId,
        uint256 price,
        address paymentToken
    )
        external
        nonReentrant
        onlyKYCVerified
        onlyAllowedToken(paymentToken)
        onlyNonZeroAmount(price)
    {
        _listPropertyWithConfirmation(tokenId, price, paymentToken, 0);
    }
    */

    function listPropertyWithConfirmationPeriod(
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
        assert(existingListing.status != PropertyStatus.LISTED && existingListing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION);
           
    
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

    //Step 2: Non-Bidding Purchases
    //Called by buyers that don't want to bid.

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
        /*
        if (listing.confirmationPeriod > 0) {
            //User wants to purchase property, but there is a confirmation period. Escrows tokens in this contract.
            _createPendingPurchase(
                tokenId,
                listing.price,
                listing.paymentToken
            );
        } else {
            //User wants to purchase property, and there is no confirmation period.
            _completePurchase(tokenId, listing.price, listing.paymentToken);
        }
        */
        //No automatic purchases, even at listing price, we need a period for the seller to confirm the purchase, do escrow, for the seller to analyze the offer.
        _createPendingPurchase(tokenId, listing.price, listing.paymentToken);
    }

    //Separate function for breaking the bidding system and buying at a competitive offer (higher than the listing price and highest bid)
    /* //marking for deprecation because this doesn't seem very usful - circumvents the bidding system.
    function purchasePropertyAtCompetitiveOffer(
        uint256 tokenId,
        uint256 offerPrice
    ) external nonReentrant onlyKYCVerified onlyNonZeroAmount(offerPrice) {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        uint256 highestBid = _getHighestActiveBid(tokenId);
        if (
            offerPrice < listing.price ||
            (highestBid > 0 && offerPrice < highestBid)
        ) {
            revert OfferPriceTooLow(
                tokenId,
                offerPrice,
                listing.price,
                highestBid
            );
        }
        if (listing.confirmationPeriod > 0) {
            //User wants to purchase property, but there is a confirmation period.
            _createPendingPurchase(tokenId, offerPrice, listing.paymentToken);
        } else {
            //User wants to purchase property, and there is no confirmation period.
            _completePurchase(tokenId, offerPrice, listing.paymentToken);
            if (highestBid > 0) {
                //Emit if this competitive offer is higher than the highest bid.
                emit CompetitivePurchase(
                    tokenId,
                    msg.sender,
                    offerPrice,
                    highestBid,
                    listing.paymentToken
                );
            }
        }
    }
    */

    function _createPendingPurchase(
        uint256 tokenId,
        uint256 settlementPrice,
        address paymentToken
    ) internal {
        PropertyListing storage listing = listings[tokenId];
        IERC20 token = IERC20(paymentToken);
        listing.status = PropertyStatus.PENDING_SELLER_CONFIRMATION; //Now entering the escrow phase. We can safely escrow the tokens because this is called by the buyer.
        uint256 deadline = block.timestamp + listing.confirmationPeriod;

        pendingPurchases[tokenId] = PendingPurchase({
            tokenId: tokenId,
            buyer: msg.sender,
            price: settlementPrice,
            paymentToken: paymentToken,
            purchaseTimestamp: block.timestamp,
            confirmationDeadline: deadline,
            fundsDeposited: true
        });

        // Check that the contract is allowed to transfer tokens on behalf of the buyer
        uint256 allowance = token.allowance(msg.sender, address(this));
        if (allowance < settlementPrice) {
            revert CannotCreatePendingPurchaseDueToInsufficientAllowance(
                address(token),
                settlementPrice,
                allowance
            );
        }

        token.safeTransferFrom(msg.sender, address(this), settlementPrice); //Buyer sends tokens to escrow.

        emit PurchaseRequested(
            tokenId,
            msg.sender,
            settlementPrice,
            paymentToken,
            deadline
        );
    }

    //As of now, this is not being called by anyone. TODO: add public function for this.
    function _completePurchase(
        uint256 tokenId,
        uint256 actualPrice,
        address paymentToken
    ) internal {
        PropertyListing storage listing = listings[tokenId];

        listing.status = PropertyStatus.SOLD;
        _cancelAllBids(tokenId);

        _processPropertyTokenPayment(
            listing.seller,
            msg.sender,
            actualPrice,
            paymentToken
        );
        manageLifePropertyNFT.safeTransferFrom(
            listing.seller,
            msg.sender,
            tokenId,
            ""
        ); //Sends the NFT to buyer

        emit PropertySold(tokenId, msg.sender, actualPrice, paymentToken);
    }

    //Step 3: Purchase confirmationss or rejections for purchases that have a confirmation period.
    //Perfom full settlement here because both the NFT and tokens are escrowed.
    //Currently this is being used for the listing price purchase. TODO: use for bidding system too.
    function confirmPurchase(uint256 tokenId) external nonReentrant {
        (
            PropertyListing storage listing,
            PendingPurchase storage purchase
        ) = _performPendingPurchaseChecks(tokenId);


        listing.status = PropertyStatus.SOLD; //This seems to be too early, I think the NFT should be escrowed first.

        //Probabaly not necessary, what's the point. Maybe some cleanup.
        //_cancelAllBids(tokenId);

        //Send the NFT to buyer,  because it's escrowed already.
        _processNFTTransfer(tokenId, purchase.buyer);

        //Send escrowed tokens to seller
        _processPropertyTokenPayment(
            listing.seller,
            purchase.buyer,
            purchase.price,
            purchase.paymentToken
        );

        emit PurchaseConfirmed(
            tokenId,
            msg.sender,
            purchase.buyer,
            purchase.price,
            purchase.paymentToken
        );
        emit PropertySold(
            tokenId,
            purchase.buyer,
            purchase.price,
            purchase.paymentToken
        );
    }

    //Rejects a particular purchase, refunds the tokens, but NOT the NFT because it's back in listed state, awaiting a new sale.
    function rejectPurchase(uint256 tokenId) external nonReentrant {
        (
            PropertyListing storage listing,
            PendingPurchase storage purchase
        ) = _performPendingPurchaseChecks(tokenId);

        _refundPendingPurchaseTokens(tokenId); //This undoes the escrow of the purchase token.

        emit PurchaseRejected(
            tokenId,
            msg.sender,
            purchase.buyer,
            purchase.price,
            purchase.paymentToken
        );

        delete pendingPurchases[tokenId]; //Delete the purchase from the pending purchases map.
        listing.status = PropertyStatus.LISTED; //Back to listed state.
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
        if (purchase.paymentToken==address(0)) {
            revert PurchaseNonExistent(tokenId);
        }

        //Listing needs to be in pending seller confirmation.
        if (listing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION) {
            revert NotInPendingSellerConfirmation(tokenId, listing.status);
        }

        if(listing.seller != msg.sender) {
            revert CallerNotSeller(tokenId, msg.sender, listing.seller);
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

    function cancelExpiredPurchase(uint256 tokenId) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        PendingPurchase storage purchase = pendingPurchases[tokenId];
        if (listing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION) {
            revert NotInPendingSellerConfirmation(tokenId, listing.status);
        }
        if (purchase.paymentToken==address(0)) {
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

    function _refundPendingPurchaseTokens(uint256 tokenId) internal {
        PendingPurchase storage purchase = pendingPurchases[tokenId];
        IERC20 token = IERC20(purchase.paymentToken);
        token.safeTransfer(purchase.buyer, purchase.price);
    }

    //Big Management Functions
    function placeBid(
        uint256 tokenId,
        uint256 bidAmount,
        address paymentToken
    )
        external
        nonReentrant
        onlyKYCVerified
        onlyAllowedToken(paymentToken)
        onlyNonZeroAmount(bidAmount)
    {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        address currentOwner = manageLifePropertyNFT.ownerOf(tokenId);
        if (currentOwner == msg.sender) {
            revert CallerIsSeller(tokenId, msg.sender, currentOwner);
        }
        if (listing.seller != currentOwner) {
            //The seller has moved the token to a different address. Bids Are not allowed anymo
            revert SellerNotOwnerOfToken(tokenId, listing.seller, currentOwner);
        }

        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];

        //There is a current bid. Allows for the increasing of the bid.
        //Increasing the bid feels unnecessary.
        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][
                existingBidIndex - 1
            ];
            require(existingBid.isActive, ErrorCodes.E202);
            require(existingBid.paymentToken == paymentToken, ErrorCodes.E302);

            uint256 oldAmount = existingBid.amount;
            require(bidAmount > oldAmount, ErrorCodes.E205);
            uint256 additionalAmount = bidAmount - oldAmount;
            IERC20 token = IERC20(paymentToken);
            require(
                token.allowance(msg.sender, address(this)) >= additionalAmount,
                ErrorCodes.E208
            );
            token.safeTransferFrom(msg.sender, address(this), additionalAmount);
        } else {
            //No current bid
            IERC20 token = IERC20(paymentToken);
            require(
                token.allowance(msg.sender, address(this)) >= bidAmount,
                ErrorCodes.E208
            );
            //Escrow the bid? This doesn't sound great.
            token.safeTransferFrom(msg.sender, address(this), bidAmount);
        }

        //The bid needs to be higher than the listing price.
        //No low balling.
        require(bidAmount >= listing.price, ErrorCodes.E206);

        //get the highest bid
        uint256 highestBid = 0;
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highestBid) {
                highestBid = bids[i].amount;
            }
        }

        //This looks strange.
        if (highestBid > 0) {
            uint256 minBid = highestBid;
            require(bidAmount >= minBid, ErrorCodes.E205);
        }

        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][
                existingBidIndex - 1
            ];
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
            bidIndexByBidder[msg.sender][tokenId] = bidsForToken[tokenId]
                .length;
        }

        emit BidPlaced(tokenId, msg.sender, bidAmount, paymentToken);
    }

    //FUNCTIONS ADAPTED FROM SIMPLEAUCTION.SOL

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
    function placeBid2(
        uint256 tokenId,
        uint128 bidAmount,
        address paymentToken
    )
        external
        onlyKYCVerified
        onlyAllowedToken(paymentToken)
        onlyNonZeroAmount(uint256(bidAmount))
    {
        PropertyListing storage listing = listings[tokenId];

        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        address currentOwner = manageLifePropertyNFT.ownerOf(tokenId);
        if (currentOwner == msg.sender) {
            revert CallerIsSeller(tokenId, msg.sender, currentOwner);
        }
        if (listing.seller != currentOwner) {
            revert SellerNotOwnerOfToken(tokenId, listing.seller, currentOwner);
        }

        uint256 requiredBid;
        if (listing.highestBid == 0) {
            // The first bid must be at least the listing price.
            requiredBid = listing.price;
        } else {
            // Subsequent bids must be at least 1 unit greater than the highest bid.
            requiredBid = uint256(listing.highestBid) + 1;
        }

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
        listing.topBids[0].paymentToken = paymentToken;
        listing.topBids[0].bidder = msg.sender;
        listing.topBids[0].amount = bidAmount;
        listing.topBids[0].bidTimestamp = block.timestamp;

        // Update the listing's highest bid information.
        listing.highestBidder = msg.sender;
        listing.highestBid = bidAmount;
    }

    function withdrawBid(uint256 tokenId) external {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        // Find the bidder's bid in the top bids
        uint8 bidIndex = TOP_BIDS_COUNT; // Use count as a sentinel for "not found"
        uint256 withdrawnAmount = 0;
        for (uint8 i = 0; i < TOP_BIDS_COUNT; i++) {
            if (listing.topBids[i].bidder == msg.sender) {
                bidIndex = i;
                withdrawnAmount = listing.topBids[i].amount;
                break;
            }
        }

        if (bidIndex == TOP_BIDS_COUNT) revert NotABidder();
        if (bidIndex == 0) revert CannotWithdrawHighestBid();

        // Remove the bid by shifting lower bids up
        for (uint8 i = bidIndex; i < TOP_BIDS_COUNT - 1; i++) {
            listing.topBids[i] = listing.topBids[i + 1];
        }
        // Clear the last spot
        delete listing.topBids[TOP_BIDS_COUNT - 1];

        //TODO: event
    }

    function acceptBid(
        uint256 tokenId,
        uint256 bidIndex,
        address expectedBidder,
        uint256 expectedAmount,
        address expectedPaymentToken
    ) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        require(
            manageLifePropertyNFT.ownerOf(tokenId) == msg.sender,
            ErrorCodes.E105
        );

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
        _processPaymentFromBalance(
            listing.seller,
            bid.amount,
            bid.paymentToken
        );
        manageLifePropertyNFT.safeTransferFrom(
            listing.seller,
            bid.bidder,
            tokenId,
            ""
        );
        emit BidAccepted(
            tokenId,
            listing.seller,
            bid.bidder,
            bid.amount,
            bid.paymentToken
        );

        _cancelOtherBids(tokenId, bid.bidder);
    }

    function _cancelAllBids(uint256 tokenId) private {
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive) {
                address bidder = bids[i].bidder;
                uint256 refundAmount = bids[i].amount;
                address paymentToken = bids[i].paymentToken;

                bids[i].isActive = false;
                bidIndexByBidder[bidder][tokenId] = 0;
                _refundBid(bidder, refundAmount, paymentToken, tokenId);

                emit BidCancelled(tokenId, bidder, refundAmount);
            }
        }
    }

    function _cancelOtherBids(uint256 tokenId, address excludeBidder) private {
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].bidder != excludeBidder) {
                address bidder = bids[i].bidder;
                uint256 refundAmount = bids[i].amount;
                address paymentToken = bids[i].paymentToken;

                bids[i].isActive = false;
                bidIndexByBidder[bidder][tokenId] = 0;
                _refundBid(bidder, refundAmount, paymentToken, tokenId);

                emit BidCancelled(tokenId, bidder, refundAmount);
            }
        }
    }

    function _refundBid(
        address bidder,
        uint256 amount,
        address paymentToken,
        uint256
    ) private {
        IERC20(paymentToken).safeTransfer(bidder, amount);
    }

    //All this does at this point is send the fees to the fee collector and the net value to the seller.
    function _processPropertyTokenPayment(
        address seller,
        address buyer,
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
            seller,
            buyer,
            amount,
            paymentToken
        );
    }

    function _processNFTTransfer(
        uint256 tokenId,
        address buyer
    ) internal {
        //NFT is escrowed, just send to to the buyer.
        // Token is escrowed, just send it from escrow to the buyer
        manageLifePropertyNFT.safeTransferFrom(
            address(this),
            buyer,
            tokenId,
            ""
        );
    }

    function _processPaymentFromBalance(
        address seller,
        uint256 amount,
        address paymentToken
    ) internal {
        (uint256 baseFee, , address feeCollector) = adminControl.feeConfig();

        uint256 fees = (amount * baseFee) / PERCENTAGE_BASE;
        uint256 netValue = amount - fees;

        IERC20 token = IERC20(paymentToken);
        token.safeTransfer(seller, netValue);
        token.safeTransfer(feeCollector, fees);
    }

    //Admin functions
    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    ) external onlyAdminControlAdmin {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        require(newPrice > 0, ErrorCodes.E104);
        require(isTokenAllowed(newPaymentToken), ErrorCodes.E301);

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
    }

    modifier onlyAdminControlAdmin() {
        require(
            adminControl.hasRole(adminControl.DEFAULT_ADMIN_ROLE(), msg.sender),
            ErrorCodes.E401
        );
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        require(
            manageLifePropertyNFT.ownerOf(tokenId) == msg.sender,
            ErrorCodes.E002
        );
        _;
    }

    modifier onlyKYCVerified() {
        if (!adminControl.isKYCVerified(msg.sender)) {
            revert NotKYCVerified(msg.sender);
        }
        _;
    }

    modifier onlyAllowedToken(address token) {
        if (!isTokenAllowed(token)) {
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

    function _calculateMinimumIncrement(
        uint256 currentHighest,
        uint256 /* newBid */
    ) private pure returns (uint256) {
        uint256 incrementPercent;
        if (currentHighest < 1 ether) {
            incrementPercent = 10;
        } else if (currentHighest < 10 ether) {
            incrementPercent = 5;
        } else {
            incrementPercent = 2;
        }

        uint256 multiplier = 100 + incrementPercent;
        require(
            currentHighest <= type(uint256).max / multiplier,
            ErrorCodes.E502
        );

        return (currentHighest * multiplier) / 100;
    }

    function _getHighestActiveBid(
        uint256 tokenId
    ) private view returns (uint256) {
        uint256 highest = 0;
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highest) {
                highest = bids[i].amount;
            }
        }
        return highest;
    }

    function updateListingBySeller(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    ) external onlyNonZeroAmount(newPrice) onlyAllowedToken(newPaymentToken) {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        require(
            manageLifePropertyNFT.ownerOf(tokenId) == msg.sender,
            ErrorCodes.E105
        );

        address currentOwner = msg.sender;
        if (listing.seller != currentOwner) {
            listing.seller = currentOwner;
        }
        if (newPaymentToken != listing.paymentToken) {
            Bid[] storage bids = bidsForToken[tokenId];
            for (uint256 i = 0; i < bids.length; i++) {
                require(!bids[i].isActive, ErrorCodes.E911);
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
        require(bidIndex > 0, ErrorCodes.E201);

        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, ErrorCodes.E202);
        require(bid.bidder == msg.sender, ErrorCodes.E203);
        uint256 refundAmount = bid.amount;
        address paymentToken = bid.paymentToken;

        bid.isActive = false;
        bidIndexByBidder[msg.sender][tokenId] = 0;
        IERC20 token = IERC20(paymentToken);
        token.safeTransfer(msg.sender, refundAmount);
        emit BidCancelled(tokenId, msg.sender, refundAmount);
    }

    function emergencyWithdrawToken(
        address token,
        uint256 amount,
        address recipient
    ) external onlyAdminControlAdmin {
        require(token != address(0), ErrorCodes.E915);
        require(recipient != address(0), ErrorCodes.E913);

        IERC20 tokenContract = IERC20(token);
        require(
            amount <= tokenContract.balanceOf(address(this)),
            ErrorCodes.E916
        );

        tokenContract.safeTransfer(recipient, amount);

        emit EmergencyTokenWithdrawal(token, recipient, amount);
    }

    //We don't want to allow direct eth transfers to the contract
    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }
}
