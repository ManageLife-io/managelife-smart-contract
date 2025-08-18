// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IManageLifePropertyNFT} from "../interfaces/IManageLifePropertyNFT.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IAdminControl} from "../interfaces/IAdminControl.sol";

/**
 * @title PropertyMarket
 * @author ManageLife
 * @dev A decentralized marketplace for buying, selling, and bidding on properties represented as NFTs.
 * This contract handles property listings, direct purchases, bidding mechanisms, and the escrow of both NFTs and payment tokens.
 * It integrates with an AdminControl contract for role-based access control and KYC verification.
 * The market supports multiple ERC20 tokens for payments and includes mechanisms to ensure fair bidding and secure settlement.
 * @dev Does not support rebasing or fee-on-transfer tokens!
 * @dev Holds only N top bids for each property, where n = TOP_BIDS_COUNT.
 * @dev Listing a property is done by the seller, and the NFT is held in escrow by this contract.
 * @dev A purchase can be done at the listing price, or by bidding on the property. Either way, the seller must confirm the purchase within the confirmation period.
 * @dev The seller can reject a purchase, or cancel it if it expires.
 * @dev To accept a bid, the seller must deactivate bidding on the property, and then accept the bid (front-run protection).
 * @dev The seller can turn bidding on and off, but there is a maximum number of times it can be reactivated.
 * @dev A bid needs to be at least some percentage above the current highest bid, to be considered valid, according to the minimumBidIncrement.
 * @dev No escrow of the payment token is done at the bid time, for capital efficiency. Only done when the seller confirms the purchase.
 * @dev The seller can choose to accept any of the top bids, not necessarily the highest one.
 * @dev This contract can be improve by: 1) adding a small bid bond for users to bid with, which can be returned to them under normal circumstances, but can be seized if their bid is not valid during a prune
 * 2) Making the end of bids be time based, not controlled by seller.
 */
contract PropertyMarket is ReentrancyGuard, ERC721Holder {
    using SafeERC20 for IERC20;

    //Constants and immutable variables
    /**
     * @dev The maximum number of top bids to track for each property listing.
     * This value is chosen for gas optimization and should not be changed after deployment.
     */
    uint8 private constant TOP_BIDS_COUNT = 10;
    /**
     * @dev The base value for percentage calculations (e.g., 10000 = 100.00%).
     * Used to express percentages with two decimal places of precision.
     */
    uint256 private constant PERCENTAGE_BASE = 10000;

    //Data Structures
    /**
     * @notice Represents a candidate for the top bids on a property.
     * @param bidder The address of the account that placed the bid.
     * @param amount The amount of the bid, relative to the token in the listing.
     * @param bidTimestamp The timestamp when the bid was placed.
     */
    struct TopBidCandidate {
        address bidder;
        uint128 amount;
        uint64 bidTimestamp;
    }

    /**
     * @notice Contains all the details of a property listed on the market.
     * @param tokenId The unique identifier for the property NFT.
     * @param price The listing price of the property.
     * @param listTimestamp The timestamp when the property was listed.
     * @param lastRenewed The timestamp when the listing was last updated.
     * @param confirmationPeriod The duration the seller has to confirm or reject a purchase.
     * @param biddingActivationCount The number of times bidding has been reactivated for this listing.
     * @param highestBid The current highest bid amount for the property.
     * @param seller The address of the property's seller.
     * @param paymentToken The ERC20 token used for payment. Non rebase or fee-on-transfer tokens allowed.
     * @param highestBidder The address of the current highest bidder.
     * @param status The current status of the property listing (e.g., LISTED, SOLD).
     * @param biddingActive A flag indicating if bidding is currently active for the property.
     * @param topBids An array holding the top bids for the property.
     */
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

    /**
     * @notice Represents a purchase that is awaiting seller confirmation for a particular property.
     * @param price The agreed-upon price for the purchase, either an accepted bid, or the listing price.
     * @param purchaseTimestamp The timestamp when the purchase was initiated.
     * @param confirmationDeadline The timestamp by which the seller must confirm the purchase.
     * @param tokenId The ID of the property NFT being purchased.
     * @param buyer The address of the buyer.
     * @param fee The protocol fee percentage for the transaction, based on PERCENTAGE_BASE.
     * @param paymentToken The ERC20 token used for the purchase.
     * @param feeCollector The address that will receive the protocol fees.
     * @param purchaseType The type of purchase.
     */
    struct PendingPurchase {
        uint128 price; // slot 0 (16)
        uint64 purchaseTimestamp; // slot 0 (8)
        uint64 confirmationDeadline; // slot 0 (8)
        uint256 tokenId; // slot 1 (32)
        address buyer; // slot 2 (20)
        uint64 fee; // slot 2 (+8) -> 28 used, 4 wasted
        address paymentToken; // slot 3 (20) -> 12 wasted
        address feeCollector; // slot 4 (20) -> 12 wasted
        PurchaseType purchaseType; // slot 5 (1)
    }

    /**
     * @notice Defines the possible states of a property listing.
     * @dev UNINITIALIZED: Default zero state. A listing should not be in this state. Only here for safety.
     * @dev LISTED: The property is actively listed for sale.
     * @dev SOLD: The property has been sold and is no longer on the market. Can be relisted.
     * @dev DELISTED: The seller has removed the property from the market. Can be relisted.
     * @dev PENDING_SELLER_CONFIRMATION: A purchase has been initiated and is awaiting the seller's approval.
     */
    enum PropertyStatus {
        UNINITIALIZED,
        LISTED,
        SOLD,
        DELISTED,
        PENDING_SELLER_CONFIRMATION
    }

    /**
     * @notice Defines the type of purchase.
     * @dev LISTING: The purchase is directly from the listing price.
     * @dev BID: The purchase is from a bid.
     */
    enum PurchaseType {
        LISTING,
        BID
    }

    //State Variables
    /**
     * @notice The minimum duration a seller can set for the purchase confirmation period.
     */
    uint256 public minConfirmationPeriod;
    /**
     * @notice The maximum duration a seller can set for the purchase confirmation period.
     */
    uint256 public maxConfirmationPeriod;
    /**
     * @notice The maximum number of times a seller can reactivate bidding on a property.
     */
    uint256 public maxToggleBiddingReactivation;
    /**
     * @notice The minimum percentage increment required for a new bid over the current highest bid, based on PERCENTAGE_BASE, in Basis Points.
     */
    uint256 public minimumBidIncrement; // e.g., 50 = 0.5%, 100 = 1%
    /**
     * @notice The instance of the ManageLifePropertyNFT contract that this market operates on.
     */
    IManageLifePropertyNFT public immutable manageLifePropertyNFT;

    /**
     * @notice A mapping of ERC20 token addresses that are permitted for use as payment. No rebasing or fee-on-transfer tokens allowed.
     */
    mapping(address => bool) public allowedPaymentTokens;
    /**
     * @notice The AdminControl contract instance for managing roles, KYC, and fees.
     */
    IAdminControl public adminControl;
    /**
     * @notice Mapping from token ID to the property listing details.
     */
    mapping(uint256 => PropertyListing) public listings;
    /**
     * @notice Mapping from token ID to details of a pending purchase.
     */
    mapping(uint256 => PendingPurchase) public pendingPurchases;

    //Events
    /**
     * @notice Emitted when a new property is listed on the market.
     * @param tokenId The ID of the listed NFT.
     * @param seller The address of the seller.
     * @param price The listing price.
     * @param paymentToken The ERC20 token for payment.
     */
    event NewListing(uint256 indexed tokenId, address indexed seller, uint128 price, address paymentToken);
    /**
     * @notice Emitted when a property is unlisted from the market.
     * @param tokenId The ID of the unlisted NFT.
     * @param seller The address of the seller who unlisted the property.
     */
    event PropertyUnlisted(uint256 indexed tokenId, address indexed seller);
    /**
     * @notice Emitted when a property is successfully sold.
     * @param tokenId The ID of the sold NFT.
     * @param buyer The address of the buyer.
     * @param price The final sale price.
     * @param paymentToken The ERC20 token used for payment.
     * @param purchaseType Tells us if the sale was from a bid or from the listing price.
     */
    event PropertySold(
        uint256 indexed tokenId,
        address indexed buyer,
        uint128 price,
        address indexed paymentToken,
        PurchaseType purchaseType
    );
    /**
     * @notice Emitted when a seller accepts a bid.
     * @param tokenId The ID of the NFT.
     * @param seller The address of the seller.
     * @param bidder The address of the bidder whose bid was accepted.
     * @param amount The accepted bid amount.
     * @param paymentToken The ERC20 token for payment.
     */
    event BidAccepted(
        uint256 indexed tokenId, address indexed seller, address indexed bidder, uint128 amount, address paymentToken
    );
    /**
     * @notice Emitted when a bid is removed or withdrawn.
     * @param tokenId The ID of the NFT.
     * @param bidder The address of the bidder.
     * @param amount The amount of the removed bid.
     */
    event BidRemoved(uint256 indexed tokenId, address indexed bidder, uint128 amount);
    /**
     * @notice Emitted when a new ERC20 token is added to the list of allowed payment tokens.
     * @param token The address of the added token.
     */
    event PaymentTokenAdded(address indexed token);
    /**
     * @notice Emitted when an ERC20 token is removed from the list of allowed payment tokens.
     * @param token The address of the removed token.
     */
    event PaymentTokenRemoved(address indexed token);
    /**
     * @notice Emitted when the payment token for a listing is changed.
     * @param tokenId The ID of the NFT.
     * @param oldToken The address of the old payment token.
     * @param newToken The address of the new payment token.
     * @param caller The address that initiated the change, can be seller or admin.
     */
    event ListingTokenChanged(
        uint256 indexed tokenId, address indexed oldToken, address indexed newToken, address caller
    );
    /**
     * @notice Emitted when the price for a listing is changed.
     * @param tokenId The ID of the NFT.
     * @param oldPrice The old price.
     * @param newPrice The new price.
     * @param caller The address that initiated the change.
     */
    event ListingPriceChanged(uint256 indexed tokenId, uint128 oldPrice, uint128 newPrice, address indexed caller);
    /**
     * @notice Emitted when tokens are withdrawn from the contract in an emergency.
     * @param token The address of the withdrawn ERC20 token.
     * @param recipient The address that received the tokens.
     * @param amount The amount of tokens withdrawn.
     */
    event EmergencyTokenWithdrawal(address indexed token, address indexed recipient, uint256 amount);
    /**
     * @notice Emitted when a buyer requests to purchase a property.
     * @param tokenId The ID of the NFT.
     * @param buyer The address of the buyer.
     * @param offerPrice The price offered by the buyer.
     * @param paymentToken The ERC20 token for payment.
     * @param confirmationDeadline The deadline for the seller to confirm.
     * @param purchaseType Tells us if the request is from a bid or from the listing price.
     */
    event PurchaseRequested(
        uint256 indexed tokenId,
        address indexed buyer,
        uint128 offerPrice,
        address indexed paymentToken,
        uint64 confirmationDeadline,
        PurchaseType purchaseType
    );
    /**
     * @notice Emitted when a seller rejects a purchase request.
     * @param tokenId The ID of the NFT.
     * @param seller The address of the seller.
     * @param buyer The address of the buyer whose request was rejected.
     * @param offerPrice The price offered.
     * @param paymentToken The ERC20 token for payment.
     * @param purchaseType Tells us if the request was from a bid or from the listing price.
     */
    event PurchaseRejected(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint128 offerPrice,
        address paymentToken,
        PurchaseType purchaseType
    );
    /**
     * @notice Emitted when a pending purchase expires without seller confirmation.
     * @param tokenId The ID of the NFT.
     * @param buyer The address of the buyer.
     * @param offerPrice The price that was offered.
     * @param paymentToken The ERC20 token for payment.
     */
    event PurchaseExpired(
        uint256 indexed tokenId,
        address indexed buyer,
        uint128 offerPrice,
        address indexed paymentToken,
        PurchaseType purchaseType
    );

    /**
     * @notice Emitted when a payment is processed and distributed.
     * @param paymentRecipient The address receiving the net sale amount (seller).
     * @param paymentSender The address that sent the funds (this contract).
     * @param amount The total amount of the payment before fees.
     * @param fees The amount deducted as protocol fees.
     * @param paymentToken The ERC20 token used for the payment.
     * @param feeCollector The address that received the fees.
     */
    event PaymentProcessed(
        address indexed paymentRecipient,
        address indexed paymentSender,
        uint256 amount,
        uint256 fees,
        address indexed paymentToken,
        address feeCollector
    );

    /**
     * @notice Emitted when a seller deactivates bidding on a property listing.
     * @param tokenId The ID of the NFT.
     * @param seller The address of the seller.
     */
    event BiddingDeactivatedForListing(uint256 indexed tokenId, address indexed seller);

    /**
     * @notice Emitted when a seller reactivates bidding on a property listing.
     * @param tokenId The ID of the NFT.
     * @param seller The address of the seller.
     * @param biddingActivationCount The new count of bidding activations.
     * @param maxBiddingActivationCount The maximum allowed count of bidding activations.
     */
    event BiddingReactivatedForListing(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 biddingActivationCount,
        uint256 maxBiddingActivationCount
    );
    /**
     * @notice Emitted when a new bid is placed on a property.
     * @param tokenId The ID of the NFT.
     * @param bidder The address of the bidder.
     * @param amount The amount of the bid.
     * @param paymentToken The ERC20 token used for the bid.
     */
    event BidPlaced(uint256 indexed tokenId, address indexed bidder, uint128 amount, address paymentToken);
    /**
     * @notice Emitted when all bids for a property are cleared, typically after a listing update.
     * @param tokenId The ID of the NFT.
     * @param clearedBy The address that triggered the clearing of bids.
     */
    event AllBidsClearedForProperty(uint256 indexed tokenId, address indexed clearedBy);

    /**
     * @notice Emitted when a bid is pruned (removed) because it is no longer valid.
     * @param tokenId The ID of the NFT.
     * @param bidder The address of the bidder whose bid was pruned.
     * @param amount The amount of the pruned bid.
     * @param reason A string indicating why the bid was pruned (e.g., "low allowance", "low balance").
     */
    event BidPruned(uint256 indexed tokenId, address indexed bidder, uint128 amount, string reason);
    /**
     * @notice Emitted when the minimum confirmation period is updated.
     * @param oldMinConfirmationPeriod The previous minimum period.
     * @param newMinConfirmationPeriod The new minimum period.
     */
    event MinConfirmationPeriodSet(uint256 oldMinConfirmationPeriod, uint256 newMinConfirmationPeriod);
    /**
     * @notice Emitted when the maximum confirmation period is updated.
     * @param oldMaxConfirmationPeriod The previous maximum period.
     * @param newMaxConfirmationPeriod The new maximum period.
     */
    event MaxConfirmationPeriodSet(uint256 oldMaxConfirmationPeriod, uint256 newMaxConfirmationPeriod);
    /**
     * @notice Emitted when the maximum number of bidding reactivations is updated.
     * @param oldMaxToggleBiddingReactivation The previous maximum count.
     * @param newMaxToggleBiddingReactivation The new maximum count.
     */
    event MaxToggleBiddingReactivationSet(
        uint256 oldMaxToggleBiddingReactivation, uint256 newMaxToggleBiddingReactivation
    );

    //Errors
    error ZeroAddress();
    error DirectEthTransferNotAllowed();
    error NotOwnerOfToken(uint256 tokenId, address owner);
    error TokenNotListed(uint256 tokenId);
    error RequestedConfirmationPeriodTooLong(uint256 period, uint256 maxPeriod);
    error RequestedConfirmationPeriodTooShort(uint256 period, uint256 minPeriod);
    error NotKYCVerified(address user);
    error NotAllowedToken(address token);
    error ZeroAmount();
    error HighestBidIsValidAndHigherThanListingPrice(uint256 tokenId, uint128 highestBid, uint128 listingPrice);
    error NotInPendingSellerConfirmation(uint256 tokenId, PropertyStatus status);
    error PurchaseNonExistent(uint256 tokenId);
    error CallerNotSeller(uint256 tokenId, address caller, address seller);
    error PurchaseConfirmationPeriodExpired(uint256 tokenId, uint256 confirmationDeadline);
    error PurchaseConfirmationPeriodNotExpired(uint256 tokenId, uint256 confirmationDeadline);
    error CallerIsSeller(uint256 tokenId, address caller, address seller);
    error BidTooLow(uint256 bidAmount, uint256 requiredBid);
    error NotATopBidder();
    error CannotWithdrawHighestBid();
    error CannotListPropertyDueToNFTNotApproved(uint256 tokenId);
    error CannotCreatePendingPurchaseDueToInsufficientAllowance(
        address token, uint256 settlementPrice, uint256 allowance
    );
    error InvalidTopBidIndex(uint256 index, uint256 topIndex);
    error NoBidsForToken(uint256 tokenId);
    error BidHasChanged(address expectedBidder, address actualBidder, uint128 expectedAmount, uint128 actualAmount);
    error NotEnoughAllowanceOrBalanceToPlaceBid(address token, uint128 bid, uint256 allowance, uint256 balance);
    error BiddingNotActive(uint256 tokenId);
    error BiddingMustNotBeActive(uint256 tokenId);
    error ListingNotChanged(uint256 tokenId);
    error InvalidToken();
    error EmergencyWithdrawAmountTooHigh();
    error OnlyAdminCanCall();
    error AdminControlMismatch(address passedAdminControl, address onNFT);
    error MaxBiddingReactivationCountReached(uint256 tokenId);
    error CallerNotSellerOrBuyer(uint256 tokenId, address caller, address seller, address buyer);
    error FeeMismatch(uint256 expectedFee, uint256 baseFee);
    error EmptyTopBid(uint256 tokenId);
    error InvalidNFTCollection(address token);
    error UnexpectedERC721Transfer(address from, uint256 tokenId);
    error BidIsValid(uint256 tokenId, uint256 topBidIndex, address bidder);
    error OnlyTokenWhitelistManagerCanCall();
    error NotNftPropertyManager();
    error OnlyProtocolParamManagerCanCall();
    error MinConfirmationPeriodTooLow(uint256 newMinConfirmationPeriod, uint256 maxConfirmationPeriod);
    error MaxConfirmationPeriodTooLow(uint256 newMaxConfirmationPeriod, uint256 minConfirmationPeriod);
    //Modifiers

    modifier onlyAdminControlAdmin() {
        if (!adminControl.hasRole(adminControl.DEFAULT_ADMIN_ROLE(), msg.sender)) {
            revert OnlyAdminCanCall();
        }
        _;
    }

    modifier onlyNftPropertyManager() {
        if (!adminControl.hasRole(adminControl.NFT_PROPERTY_MANAGER_ROLE(), msg.sender)) {
            revert NotNftPropertyManager();
        }
        _;
    }

    modifier onlyProtocolParamManager() {
        if (!adminControl.hasRole(adminControl.PROTOCOL_PARAM_MANAGER_ROLE(), msg.sender)) {
            revert OnlyProtocolParamManagerCanCall();
        }
        _;
    }

    modifier onlyTokenWhitelistManager() {
        if (!adminControl.hasRole(adminControl.TOKEN_WHITELIST_MANAGER_ROLE(), msg.sender)) {
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

    /**
     * @notice Initializes the PropertyMarket contract.
     * @param _manageLifePropertyNFT The address of the ManageLifePropertyNFT contract.
     * @param _adminControl The address of the AdminControl contract.
     */
    constructor(IManageLifePropertyNFT _manageLifePropertyNFT, IAdminControl _adminControl) {
        if (address(_manageLifePropertyNFT) == address(0)) {
            revert ZeroAddress();
        }

        address adminOnNFT = address(_manageLifePropertyNFT.adminController());
        if (adminOnNFT != address(_adminControl)) {
            revert AdminControlMismatch(address(_adminControl), adminOnNFT);
        }

        manageLifePropertyNFT = _manageLifePropertyNFT;
        adminControl = _adminControl;
        minimumBidIncrement = 100; //defaults to 1%
        minConfirmationPeriod = 5 days; //defaults to 5 days
        maxConfirmationPeriod = 14 days; //defaults to 14 days
        maxToggleBiddingReactivation = 5; //defaults to 5
    }

    //Receive function

    /**
     * @notice Reverts direct Ether transfers to the contract to prevent accidental sends.
     */
    //We don't want to allow direct eth transfers to the contract
    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }

    //External functions
    /**
     * @notice Adds an ERC20 token to the whitelist of allowed payment tokens.
     * @dev Can only be called by an account with the TOKEN_WHITELIST_MANAGER_ROLE.
     * @param token The address of the ERC20 token to add.
     */
    function addAllowedToken(address token) external onlyTokenWhitelistManager {
        if (token == address(0)) {
            revert InvalidToken();
        }
        allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token);
    }

    /**
     * @notice Removes an ERC20 token from the whitelist of allowed payment tokens.
     * @dev This only affects new listings; existing listings with this token remain valid.
     * @dev Can only be called by an account with the TOKEN_WHITELIST_MANAGER_ROLE.
     * @param token The address of the ERC20 token to remove.
     */
    function removeAllowedToken(address token) external onlyTokenWhitelistManager {
        if (token == address(0)) {
            revert InvalidToken();
        }
        allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token);
    }

    //Step 1: Listing and unlisting
    /**
     * @notice Lists a property for sale on the marketplace.
     * @dev The sender must be the owner of the NFT and have approved this contract to transfer it.
     * @dev The NFT will be held in escrow by this contract upon successful sale or unlisting.
     * @param tokenId The ID of the NFT to list.
     * @param price The listing price.
     * @param paymentToken The address of the ERC20 token for payment.
     * @param confirmationPeriod The time in seconds the seller has to confirm a purchase.
     */
    function listProperty(uint256 tokenId, uint128 price, address paymentToken, uint64 confirmationPeriod)
        external
        nonReentrant
        onlyKYCVerified
        onlyAllowedToken(paymentToken)
        onlyNonZeroAmount(price)
    {
        if (confirmationPeriod > maxConfirmationPeriod) {
            revert RequestedConfirmationPeriodTooLong(confirmationPeriod, maxConfirmationPeriod);
        }
        if (confirmationPeriod < minConfirmationPeriod) {
            revert RequestedConfirmationPeriodTooShort(confirmationPeriod, minConfirmationPeriod);
        }
        _listPropertyWithConfirmation(tokenId, price, paymentToken, confirmationPeriod);
    }

    /**
     * @notice Unlists a property from the marketplace.
     * @dev The NFT held in escrow is returned to the seller.
     * @dev Can only be called by the seller of the property, in the listed state, not in a pending purchase.
     * @param tokenId The ID of the NFT to unlist.
     */
    function unlistProperty(uint256 tokenId) external onlyKYCVerified onlySellerCanCall(tokenId) nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        listing.status = PropertyStatus.DELISTED;

        manageLifePropertyNFT.safeTransferFrom(address(this), msg.sender, tokenId);

        emit PropertyUnlisted(tokenId, msg.sender);
    }

    /**
     * @notice Updates the price and/or payment token of a listing by an admin.
     * @dev This will clear all existing bids on the property.
     * @dev Can only be called by an account with the NFT_PROPERTY_MANAGER_ROLE.
     * @param tokenId The ID of the NFT to update.
     * @param newPrice The new listing price.
     * @param newPaymentToken The new ERC20 payment token.
     */
    function updateListingByAdmin(uint256 tokenId, uint128 newPrice, address newPaymentToken)
        external
        onlyNonZeroAmount(newPrice)
        onlyAllowedToken(newPaymentToken)
        onlyNftPropertyManager
    {
        _updateListing(tokenId, newPrice, newPaymentToken);
    }

    /**
     * @notice Updates the price and/or payment token of a listing by the seller.
     * @notice Doesn't need reentrancy, but it's there to prevent cross-function reentrancy.
     * @dev This will clear all existing bids on the property.
     * @param tokenId The ID of the NFT to update.
     * @param newPrice The new listing price.
     * @param newPaymentToken The new ERC20 payment token.
     */
    function updateListingBySeller(uint256 tokenId, uint128 newPrice, address newPaymentToken)
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

    /**
     * @notice Initiates a purchase of a property at its current listing price.
     * @dev This creates a pending purchase and escrows the buyer's funds. The seller must confirm the purchase.
     * @dev This function will fail if there is an active bid higher than the listing price.
     * @param tokenId The ID of the NFT to purchase.
     * @param expectedFee The expected protocol fee percentage, used for front-run protection.
     */
    function purchasePropertyAtListingPrice(uint256 tokenId, uint256 expectedFee)
        external
        nonReentrant
        onlyKYCVerified
    {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        uint128 highestBid = listing.highestBid;
        if (highestBid > listing.price) {
            TopBidCandidate storage topBid = listing.topBids[0];
            uint256 allowance = IERC20(listing.paymentToken).allowance(topBid.bidder, address(this));
            uint256 balance = IERC20(listing.paymentToken).balanceOf(topBid.bidder);
            if (allowance >= topBid.amount && balance >= topBid.amount) {
                revert HighestBidIsValidAndHigherThanListingPrice(tokenId, highestBid, listing.price);
            }
        }
        _createPendingPurchase(
            tokenId, listing.price, listing.paymentToken, msg.sender, expectedFee, PurchaseType.LISTING
        );
    }

    //Step 3: Purchase confirmations or rejections, and dealing with expired purchases.

    /**
     * @notice Confirms a pending purchase, completing the sale.
     * @dev Transfers the NFT to the buyer and the payment (less fees) to the seller.
     * @dev Can only be called by the seller before the confirmation period expires.
     * @param tokenId The ID of the NFT being purchased.
     */
    function confirmPurchase(uint256 tokenId) external nonReentrant onlySellerCanCall(tokenId) onlyKYCVerified {
        (PropertyListing storage listing, PendingPurchase storage purchase) = _performPendingPurchaseChecks(tokenId);

        //Send the NFT to buyer,  because it's escrowed already.
        _processNFTTransfer(tokenId, purchase.buyer);

        //Send escrowed tokens to seller
        _processPropertyTokenPayment(
            listing.seller, purchase.price, purchase.paymentToken, purchase.fee, purchase.feeCollector
        );

        listing.status = PropertyStatus.SOLD;
        delete pendingPurchases[tokenId];

        emit PropertySold(tokenId, purchase.buyer, purchase.price, purchase.paymentToken, purchase.purchaseType);
    }

    /**
     * @notice Rejects a pending purchase.
     * @dev The buyer's escrowed funds are returned. The property is returned to the LISTED state.
     * @dev If the purchase was from a bid, that bid is removed.
     * @dev Can only be called by the seller before the confirmation period expires.
     * @param tokenId The ID of the NFT.
     */
    function rejectPurchase(uint256 tokenId) external onlySellerCanCall(tokenId) onlyKYCVerified nonReentrant {
        (PropertyListing storage listing, PendingPurchase storage purchase) = _performPendingPurchaseChecks(tokenId);

        address buyer = purchase.buyer;

        _refundPendingPurchaseTokens(tokenId); //This undoes the escrow of the purchase token.

        emit PurchaseRejected(
            tokenId, msg.sender, purchase.buyer, purchase.price, purchase.paymentToken, purchase.purchaseType
        );

        delete pendingPurchases[tokenId]; //Delete the purchase from the pending purchases map.
        listing.status = PropertyStatus.LISTED; //Back to listed state.
        if (listing.price != purchase.price) {
            //if this purchase is from bidding, remove the bid.
            _removeTopBid(tokenId, buyer);
        }
    }

    /**
     * @notice Allows a anyone to check and remove invalid bids from the top bids list.
     * @dev A bid is considered invalid if the bidder no longer has sufficient balance or allowance for the payment token.
     * @dev Provides front-run protection by requiring expected bidder and amount.
     * @dev In the future, we can reward the caller of this function with a small fee, to incentivize them to do this, and keep auctions fair, and prevent fake bidders.
     * @param tokenId The ID of the NFT.
     * @param topBidIndex The index of the bid to check in the `topBids` array.
     * @param expectedBidder The expected address of the bidder at the given index.
     * @param expectedAmount The expected bid amount at the given index.
     * @return removed True if the bid was invalid and removed, otherwise the call reverts.
     */
    function pruneInvalidBids(uint256 tokenId, uint256 topBidIndex, address expectedBidder, uint128 expectedAmount)
        external
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
        if (topBid.bidder != expectedBidder || topBid.amount != expectedAmount) {
            revert BidHasChanged(expectedBidder, topBid.bidder, expectedAmount, topBid.amount);
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
     * @notice Doesn't need reentrancy, but it's there to prevent cross-function reentrancy.
     * @notice Funds are not escrowed at bid time, for capital efficiency.
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
     * @param tokenId The ID of the NFT to bid on.
     * @param bidAmount The amount of the bid.
     */
    function placeBid(uint256 tokenId, uint128 bidAmount)
        external
        onlyKYCVerified
        onlyNonZeroAmount(bidAmount)
        nonReentrant
    {
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
            revert NotEnoughAllowanceOrBalanceToPlaceBid(listing.paymentToken, bidAmount, allowance, balance);
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
     * @notice Doesn't need reentrancy, but it's there to prevent cross-function reentrancy.
     * @param tokenId The ID of the NFT from which to withdraw the bid.
     */
    function withdrawBid(uint256 tokenId) external nonReentrant onlyKYCVerified {
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

    /**
     * @notice Toggles the bidding active status for a listed property.
     * @notice Doesn't need reentrancy, but it's there to prevent cross-function reentrancy.
     * /**
     * @dev This mechanism was implemented to prevent griefing/DoS attacks against the acceptBid function.
     * However, it allows the seller to toggle the bidding status to fish for better bids, which could frustrate bidders.
     * This is considered a reasonable tradeoff, but it does give the seller more power.
     * To prevent abuse, a maximum number of bidding reactivations is enforced, requiring the seller to eventually accept a bid.
     * This could be made more fair by having the bid status depend on time.
     *
     * @dev Can only be called by the seller. There's a maximum number of times bidding can be reactivated.
     * @param tokenId The ID of the NFT.
     * @return The new bidding status (true if active, false if inactive).
     */
    function toggleBiddingActiveStatus(uint256 tokenId)
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
            if (listing.biddingActivationCount >= maxToggleBiddingReactivation) {
                revert MaxBiddingReactivationCountReached(tokenId);
            }
            listing.biddingActive = true;
            listing.biddingActivationCount++;
            emit BiddingReactivatedForListing(
                tokenId, msg.sender, listing.biddingActivationCount, maxToggleBiddingReactivation
            );
        }
        return listing.biddingActive;
    }

    /**
     * @notice Allows a seller to accept one of the top bids.
     * @dev Bidding must be deactivated on the listing before a bid can be accepted.
     * @dev This creates a pending purchase, which the seller must then confirm to finalize the sale.
     * @dev Provides front-run protection by requiring expected bidder and amount.
     * @param tokenId The ID of the NFT.
     * @param topBidIndex The index of the bid to accept in the `topBids` array.
     * @param expectedBidder The expected address of the bidder being accepted.
     * @param expectedAmount The expected amount of the bid being accepted.
     * @param expectedFee The expected protocol fee percentage.
     */
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
        if (topBid.bidder != expectedBidder || topBid.amount != expectedAmount) {
            revert BidHasChanged(expectedBidder, topBid.bidder, expectedAmount, topBid.amount);
        }

        _createPendingPurchase(
            tokenId, topBid.amount, listing.paymentToken, topBid.bidder, expectedFee, PurchaseType.BID
        );
        listing.biddingActive = false; //Not necessary, but correct.
        emit BidAccepted(tokenId, listing.seller, topBid.bidder, topBid.amount, listing.paymentToken);
    }

    /**
     * @notice Cancels a pending purchase that has passed its confirmation deadline, callable by seller or buyer.
     * @dev Returns the escrowed funds to the buyer and puts the property back into the LISTED state.
     * @dev Can be called by either the seller or the buyer of the expired purchase.
     * @param tokenId The ID of the NFT with the expired purchase.
     */
    function cancelExpiredPurchase(uint256 tokenId) external nonReentrant onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        PendingPurchase storage purchase = pendingPurchases[tokenId];

        if (listing.seller != msg.sender && purchase.buyer != msg.sender) {
            revert CallerNotSellerOrBuyer(tokenId, msg.sender, listing.seller, purchase.buyer);
        }

        if (listing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION) {
            revert NotInPendingSellerConfirmation(tokenId, listing.status);
        }
        if (purchase.paymentToken == address(0)) {
            revert PurchaseNonExistent(tokenId);
        }
        if (block.timestamp <= purchase.confirmationDeadline) {
            revert PurchaseConfirmationPeriodNotExpired(tokenId, purchase.confirmationDeadline);
        }

        if (listing.price != purchase.price) {
            //if this purchase is from bidding, remove the bid.
            _removeTopBid(tokenId, purchase.buyer);
        }

        _refundPendingPurchaseTokens(tokenId); //Undo escrow of the purchase token.

        listing.status = PropertyStatus.LISTED; //Back to listed state.

        emit PurchaseExpired(tokenId, purchase.buyer, purchase.price, purchase.paymentToken, purchase.purchaseType);
        delete pendingPurchases[tokenId]; //Delete the purchase from the pending purchases map.
    }

    //Configuration functions
    /**
     * @notice Sets the minimum confirmation period for new listings.
     * @dev Can only be called by an account with the PROTOCOL_PARAM_MANAGER_ROLE.
     * @param newMinConfirmationPeriod The new minimum period in seconds.
     */
    function setMinConfirmationPeriod(uint256 newMinConfirmationPeriod) external onlyProtocolParamManager {
        if (newMinConfirmationPeriod == 0) {
            revert ZeroAmount();
        }
        if (newMinConfirmationPeriod > maxConfirmationPeriod) {
            revert MinConfirmationPeriodTooLow(newMinConfirmationPeriod, maxConfirmationPeriod);
        }
        uint256 oldMinConfirmationPeriod = minConfirmationPeriod;
        minConfirmationPeriod = newMinConfirmationPeriod;
        emit MinConfirmationPeriodSet(oldMinConfirmationPeriod, newMinConfirmationPeriod);
    }

    /**
     * @notice Sets the maximum confirmation period for new listings.
     * @dev Can only be called by an account with the PROTOCOL_PARAM_MANAGER_ROLE.
     * @param newMaxConfirmationPeriod The new maximum period in seconds.
     */
    function setMaxConfirmationPeriod(uint256 newMaxConfirmationPeriod) external onlyProtocolParamManager {
        if (newMaxConfirmationPeriod < minConfirmationPeriod) {
            revert MaxConfirmationPeriodTooLow(newMaxConfirmationPeriod, minConfirmationPeriod);
        }
        uint256 oldMaxConfirmationPeriod = maxConfirmationPeriod;
        maxConfirmationPeriod = newMaxConfirmationPeriod;
        emit MaxConfirmationPeriodSet(oldMaxConfirmationPeriod, newMaxConfirmationPeriod);
    }

    /**
     * @notice Sets the maximum number of times a seller can reactivate bidding on a listing.
     * @dev Can only be called by an account with the PROTOCOL_PARAM_MANAGER_ROLE.
     * @param newMaxToggleBiddingReactivation The new maximum count.
     */
    function setMaxToggleBiddingReactivation(uint256 newMaxToggleBiddingReactivation)
        external
        onlyProtocolParamManager
    {
        if (newMaxToggleBiddingReactivation == 0) {
            revert ZeroAmount();
        }
        uint256 oldMaxToggleBiddingReactivation = maxToggleBiddingReactivation;
        maxToggleBiddingReactivation = newMaxToggleBiddingReactivation;
        emit MaxToggleBiddingReactivationSet(oldMaxToggleBiddingReactivation, newMaxToggleBiddingReactivation);
    }

    //Admin Emergency functions
    /**
     * @notice Allows an admin to withdraw any ERC20 tokens from this contract in an emergency.
     * @dev This is a failsafe and should be used with extreme caution.
     * @dev Consider adding a time lock to this function for enhanced security. TODO: we need to add a time lock to this.
     * @param token The address of the ERC20 token to withdraw.
     * @param amount The amount of tokens to withdraw.
     * @param recipient The address to receive the withdrawn tokens.
     */
    function emergencyWithdrawToken(address token, uint256 amount, address recipient)
        external
        onlyAdminControlAdmin
        nonReentrant
    {
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

    /**
     * @notice Retrieves the main details of a property listing.
     * @param tokenId The ID of the NFT.
     * @return seller The seller's address.
     * @return price The listing price.
     * @return paymentToken The ERC20 payment token address.
     * @return status The current status of the listing.
     * @return listTimestamp The timestamp of when it was listed.
     * @return confirmationPeriod The confirmation period in seconds.
     * @return biddingActive Whether bidding is currently active.
     * @return highestBidder The address of the highest bidder.
     * @return highestBid The amount of the highest bid.
     */
    function getListingDetails(uint256 tokenId)
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

    /**
     * @notice Retrieves the list of top bids for a specific property.
     * @param tokenId The ID of the NFT.
     * @return An array of `TopBidCandidate` structs representing the top bids.
     */
    function getTopBidsForListing(uint256 tokenId) external view returns (TopBidCandidate[TOP_BIDS_COUNT] memory) {
        PropertyListing storage listing = listings[tokenId];
        return listing.topBids;
    }

    //ERC721Receiver interface

    /**
     * @notice Handles the receipt of an NFT.
     * @dev This function is part of the ERC721 standard. It ensures that NFTs are only
     * accepted into this contract as part of the `listProperty` flow.
     * @param from The address which sent the NFT.
     * @param tokenId The ID of the NFT.
     * @return A selector indicating that the contract can receive ERC721 tokens.
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes memory data)
        public
        override(ERC721Holder)
        returns (bytes4)
    {
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

    function _listPropertyWithConfirmation(uint256 tokenId, uint128 price, address paymentToken, uint64 period)
        internal
    {
        address currentOwner = manageLifePropertyNFT.ownerOf(tokenId);
        if (currentOwner != msg.sender) {
            revert NotOwnerOfToken(tokenId, currentOwner);
        }
        PropertyListing storage existingListing = listings[tokenId];

        //Should never happen, that's why it's an assert. The NFT is escrowed, so it cannot be listed twice.
        assert(
            existingListing.status != PropertyStatus.LISTED
                && existingListing.status != PropertyStatus.PENDING_SELLER_CONFIRMATION
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
            !manageLifePropertyNFT.isApprovedForAll(msg.sender, address(this))
                && manageLifePropertyNFT.getApproved(tokenId) != address(this)
        ) {
            revert CannotListPropertyDueToNFTNotApproved(tokenId);
        }

        // Move the NFT to this contract (escrow) when listing
        manageLifePropertyNFT.safeTransferFrom(msg.sender, address(this), tokenId);

        emit NewListing(tokenId, msg.sender, price, paymentToken);
    }

    function _createPendingPurchase(
        uint256 tokenId,
        uint128 settlementPrice,
        address paymentToken,
        address buyer,
        uint256 expectedFee,
        PurchaseType purchaseType
    ) internal {
        PropertyListing storage listing = listings[tokenId];
        IERC20 token = IERC20(paymentToken);
        listing.status = PropertyStatus.PENDING_SELLER_CONFIRMATION; //Now entering the escrow phase. We can safely escrow the tokens because this is called by the buyer.
        uint256 deadline = block.timestamp + listing.confirmationPeriod;
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig(); //Fee should be obtaiend at this stage to prevent malicious changing at settlement time.

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
            feeCollector: feeCollector,
            purchaseType: purchaseType
        });

        // Check that the contract is allowed to transfer tokens on behalf of the buyer
        uint256 allowance = token.allowance(buyer, address(this));
        if (allowance < settlementPrice) {
            revert CannotCreatePendingPurchaseDueToInsufficientAllowance(address(token), settlementPrice, allowance);
        }

        token.safeTransferFrom(buyer, address(this), settlementPrice); //Buyer sends tokens to escrow.

        emit PurchaseRequested(tokenId, buyer, settlementPrice, paymentToken, uint64(deadline), purchaseType);
    }

    function _performPendingPurchaseChecks(uint256 tokenId)
        internal
        view
        returns (PropertyListing storage listing, PendingPurchase storage purchase)
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
            revert PurchaseConfirmationPeriodExpired(tokenId, purchase.confirmationDeadline);
        }
        return (listing, purchase);
    }

    function _refundPendingPurchaseTokens(uint256 tokenId) internal {
        PendingPurchase storage purchase = pendingPurchases[tokenId];
        IERC20 token = IERC20(purchase.paymentToken);
        token.safeTransfer(purchase.buyer, purchase.price);
    }

    function _removeTopBid(uint256 tokenId, address bidder) internal returns (bool) {
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
        emit PaymentProcessed(tokenRecipient, address(this), amount, fees, paymentToken, feeCollector);
    }

    function _processNFTTransfer(uint256 tokenId, address buyer) internal {
        //NFT is escrowed, just send to to the buyer.
        // Token is escrowed, just send it from escrow to the buyer
        manageLifePropertyNFT.safeTransferFrom(address(this), buyer, tokenId, "");
    }

    function _updateListing(uint256 tokenId, uint128 newPrice, address newPaymentToken) internal {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        if (listing.paymentToken == newPaymentToken && listing.price == newPrice) {
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
            emit ListingTokenChanged(tokenId, listing.paymentToken, newPaymentToken, msg.sender);
            listing.paymentToken = newPaymentToken;
        }
        if (listing.price != newPrice) {
            emit ListingPriceChanged(tokenId, listing.price, newPrice, msg.sender);
            listing.price = newPrice;
        }

        listing.lastRenewed = uint64(block.timestamp);
    }

    function _getRequiredBid(PropertyListing storage listing) internal view returns (uint256) {
        if (listing.highestBid == 0) {
            // First bid must exceed the listing price by at least 1 unit
            return listing.price + 1;
        }
        uint256 increment = (uint256(listing.highestBid) * minimumBidIncrement) / PERCENTAGE_BASE;
        if (increment == 0) {
            increment = 1;
        }
        return uint256(listing.highestBid) + increment;
    }
}
