// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IManageLifePropertyNFT} from "../interfaces/IManageLifePropertyNFT.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IAdminControl} from "../interfaces/IAdminControl.sol";
import {RescueERC20Timelock} from "../governance/RescueERC20Timelock.sol";

/**
 * @title PropertyMarket
 * @author ManageLife
 * @dev A decentralized marketplace for buying, selling properties represented as NFTs, with the ability to send and accept offers.
 * @dev Listings have versioning, so that we can validate offers and purchases if the listing is updated, without needing to do deletions.
 * @dev Versions increments on new listings and each listing update; it’s included in events so indexers/UIs can ignore stale versions.
 */
contract PropertyMarket is ReentrancyGuard, ERC721Holder,RescueERC20Timelock {
    using SafeERC20 for IERC20;

    //Constants and immutable variables, these should NEVER change after deployment.
    /**
     * @dev The base value for percentage calculations (e.g., 10000 = 100.00%).
     * Used to express percentages with two decimal places of precision.
     */
    uint256 private constant PERCENTAGE_BASE = 10000;

    //Data Structures

    struct PropertyListing {
        // slot 0
        uint128 price;
        uint64 listTimestamp;
        uint64 lastRenewed;
        // slot 1
        address seller; // 20
        uint64 confirmationPeriod; // 8
        PropertyStatus status; // 1
        // slot 2
        address paymentToken; // 20
        // slot 3
        uint256 reviewingOffersUntil; // 32
    }

    /**
     * @notice Represents a purchase that is awaiting seller confirmation for a particular property.
     * @param price The agreed-upon price for the purchase, either an accepted offer, or the listing price.
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
        // slot 0
        uint128 price;
        uint64 purchaseTimestamp;
        uint64 confirmationDeadline;
        // slot 1
        uint256 tokenId;
        // slot 2
        address buyer;
        uint64 fee;
        PurchaseType purchaseType;
        // slot 3
        address paymentToken;
        // slot 4
        address feeCollector;
    }

    /**
     * @notice Represents an offer made by a potential buyer for a property.
     * @param forListingVersion The version of the listing the offer is for.
     * @param amount The amount of the offer.
     * @param validUntil The timestamp until which the offer is valid. If 0, it does not expire.
     * @param timestamp The timestamp when the offer was made.
     */
    struct Offer {
        uint256 forListingVersion; // slot 0
        uint128 amount; // slot 1 (16)
        uint64 validUntil; // slot 1 (8)
        uint64 timestamp; // slot 1 (8)
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
     * @dev OFFER: The purchase is from an offer.
     */
    enum PurchaseType {
        LISTING,
        OFFER
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
     * @notice The maximum duration an offer can be valid for.
     */
    uint256 public maxOfferTTL;

    /**
     * @notice The duration the seller can review offers for a listing, before more offers or a buy it now purchase can be made.
     */
    uint256 public offerReviewPeriod;

    /**
     * @notice The instance of the ManageLifePropertyNFT contract that this market operates on.
     */
    IManageLifePropertyNFT public manageLifePropertyNFT;

    // ============ Function IDs for Pausing ==========
    bytes32 public constant LISTING_OPERATIONS = keccak256("LISTING_OPERATIONS");
    bytes32 public constant OFFER_OPERATIONS = keccak256("OFFER_OPERATIONS");
    bytes32 public constant PURCHASE_OPERATIONS = keccak256("PURCHASE_OPERATIONS");

    /**
     * @notice A mapping of ERC20 token addresses that are permitted for use as payment. No rebasing or fee-on-transfer tokens allowed.
     */
    mapping(address => bool) public allowedPaymentTokens;

    /**
     * @notice Mapping from token ID to the property listing details.
     */
    mapping(uint256 => PropertyListing) public listings;

    /**
     * @notice Mapping from token ID to the latest version of the listing.
     */
    mapping(uint256 => uint256) public listingVersions;

    /**
     * @notice Mapping from token ID to address of the user that created the offer.
     */
    mapping(uint256 => mapping(address => Offer)) public offers;

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
     * @param confirmationPeriod The confirmation period for the listing.
     * @param listingVersion The version of the listing.
     */
    event NewListing(
        uint256 indexed tokenId,
        address indexed seller,
        uint128 price,
        address paymentToken,
        uint64 confirmationPeriod,
        uint256 indexed listingVersion
    );
    /**
     * @notice Emitted when a property is unlisted from the market.
     * @param tokenId The ID of the unlisted NFT.
     * @param seller The address of the seller who unlisted the property.
     * @param listingVersion The version of the listing.
     */
    event PropertyUnlisted(uint256 indexed tokenId, address indexed seller, uint256 indexed listingVersion);
    /**
     * @notice Emitted when a property is successfully sold.
     * @param tokenId The ID of the sold NFT.
     * @param buyer The address of the buyer.
     * @param price The final sale price.
     * @param paymentToken The ERC20 token used for payment.
     * @param purchaseType Tells us if the sale was from an offer or from the listing price.
     * @param listingVersion The version of the listing.
     */
    event PropertySold(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint128 price,
        address paymentToken,
        PurchaseType purchaseType,
        uint256 listingVersion
    );

    /**
     * @notice Emitted when a seller accepts an offer for a property listing.
     * @param tokenId The ID of the NFT for which the offer was accepted.
     * @param seller The address of the seller who accepted the offer.
     * @param offerFrom The address of the user whose offer was accepted.
     * @param offerAmount The amount of the accepted offer.
     * @param paymentToken The ERC20 token address used for the offer.
     * @param forListingVersion The version of the listing the offer was for.
     */
    event OfferAccepted(
        uint256 indexed tokenId,
        address seller,
        address indexed offerFrom,
        uint128 offerAmount,
        address paymentToken,
        uint256 indexed forListingVersion
    );

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
     * @param listingVersion The version of the listing.
     */
    event ListingTokenChanged(
        uint256 indexed tokenId,
        address oldToken,
        address indexed newToken,
        address caller,
        uint256 indexed listingVersion
    );
    /**
     * @notice Emitted when the price for a listing is changed.
     * @param tokenId The ID of the NFT.
     * @param oldPrice The old price.
     * @param newPrice The new price.
     * @param caller The address that initiated the change, can be seller or admin.
     * @param listingVersion The version of the listing.
     */
    event ListingPriceChanged(
        uint256 indexed tokenId,
        uint128 oldPrice,
        uint128 newPrice,
        address indexed caller,
        uint256 indexed listingVersion
    );
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
     * @param price The price offered by the buyer.
     * @param paymentToken The ERC20 token for payment.
     * @param confirmationDeadline The deadline for the seller to confirm.
     * @param purchaseType Tells us if the request is from an offer or from the listing price.
     * @param fee The fee for the purchase, in basis points.
     * @param feeCollector The address that will receive the fees.
     * @param listingVersion The version of the listing.
     */
    event PurchaseRequested(
        uint256 indexed tokenId,
        address indexed buyer,
        uint128 price,
        address paymentToken,
        uint64 confirmationDeadline,
        PurchaseType purchaseType,
        uint256 fee,
        address feeCollector,
        uint256 indexed listingVersion
    );
    /**
     * @notice Emitted when a seller rejects a purchase request.
     * @param tokenId The ID of the NFT.
     * @param seller The address of the seller.
     * @param buyer The address of the buyer whose request was rejected.
     * @param price The price offered.
     * @param paymentToken The ERC20 token for payment.
     * @param purchaseType Tells us if the request was from an offer or from the listing price.
     */
    event PurchaseRejected(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint128 price,
        address paymentToken,
        PurchaseType purchaseType
    );
    /**
     * @notice Emitted when a pending purchase expires without seller confirmation.
     * @param tokenId The ID of the NFT.
     * @param buyer The address of the buyer.
     * @param price The price that was offered.
     * @param paymentToken The ERC20 token for payment.
     * @param purchaseType Tells us if the request was from an offer or from the listing price.
     */
    event PurchaseExpired(
        uint256 indexed tokenId,
        address indexed buyer,
        uint128 price,
        address indexed paymentToken,
        PurchaseType purchaseType
    );

    /**
     * @notice Emitted when a payment is processed and distributed.
     * @param tokenId The ID of the NFT.
     * @param paymentRecipient The address receiving the net sale amount (seller).
     * @param amount The total amount of the payment before fees.
     * @param fees The amount deducted as protocol fees.
     * @param paymentToken The ERC20 token used for the payment.
     * @param feeCollector The address that received the fees.
     * @param listingVersion The version of the listing.
     */
    event PaymentProcessed(
        uint256 indexed tokenId,
        address indexed paymentRecipient,
        uint256 amount,
        uint256 fees,
        address indexed paymentToken,
        address feeCollector,
        uint256 listingVersion
    );

    /**
     * @notice Emitted when a seller ends the reviewing offers period for a listing.
     * @param tokenId The ID of the NFT.
     * @param seller The address of the seller.
     * @param listingVersion The version of the listing.
     */
    event SellerNoLongerReviewingOffersForListing(
        uint256 indexed tokenId, address indexed seller, uint256 indexed listingVersion
    );

    /**
     * @notice Emitted when a seller triggers the reviewing offers state for a listing.
     * @param tokenId The ID of the NFT.
     * @param seller The address of the seller.
     * @param reviewingOffersUntil The timestamp when the reviewing offers period ends.
     * @param listingVersion The version of the listing.
     */
    event SellerReviewingOffersForListingUntil(
        uint256 indexed tokenId, address indexed seller, uint256 reviewingOffersUntil, uint256 indexed listingVersion
    );

    /**
     * @notice Emitted when an offer is placed on a property listing.
     * @param tokenId The ID of the NFT for which the offer is placed.
     * @param from The address of the user placing the offer.
     * @param amount The amount of the offer.
     * @param paymentToken The ERC20 token address used for the offer.
     * @param forListingVersion The version of the listing the offer is for.
     * @param validUntil The timestamp until which the offer is valid.
     * @param isNewOffer Indicates whether this is a new offer (true) or an update to an existing offer (false).
     */
    event OfferPlaced(
        uint256 indexed tokenId,
        address indexed from,
        uint128 amount,
        address paymentToken,
        uint256 indexed forListingVersion,
        uint64 validUntil,
        bool isNewOffer
    );

    /**
     * @notice Emitted when an offer is withdrawn by the user.
     * @param tokenId The ID of the NFT for which the offer was withdrawn.
     * @param from The address of the user withdrawing the offer.
     * @param amount The amount of the withdrawn offer.
     * @param forListingVersion The version of the listing the offer was for.
     */
    event OfferWithdraw(
        uint256 indexed tokenId, address indexed from, uint128 amount, uint256 indexed forListingVersion
    );

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
     * @notice Emitted when the maximum offer time-to-live (TTL) is updated.
     * @param oldMaxOfferTTL The previous maximum offer TTL.
     * @param newMaxOfferTTL The new maximum offer TTL.
     */
    event MaxOfferTTLSet(uint256 oldMaxOfferTTL, uint256 newMaxOfferTTL);

    /**
     * @notice Emitted when the offer review period is updated.
     * @param oldOfferReviewPeriod The previous offer review period.
     * @param newOfferReviewPeriod The new offer review period.
     */
    event OfferReviewPeriodSet(uint256 oldOfferReviewPeriod, uint256 newOfferReviewPeriod);

    /**
     * @notice Emitted when the ManageLifePropertyNFT contract is updated.
     * @param oldManageLifePropertyNFTContract The previous ManageLifePropertyNFT contract.
     * @param newManageLifePropertyNFTContract The new ManageLifePropertyNFT contract.
     */
    event ManageLifePropertyNFTContractUpdated(address oldManageLifePropertyNFTContract, address newManageLifePropertyNFTContract);

    /**
     * @notice Emitted when the AdminControl contract is updated.
     * @param oldAdminControl The previous AdminControl contract.
     * @param newAdminControl The new AdminControl contract.
     */
    event AdminControlUpdated(address oldAdminControl, address newAdminControl);

    //Errors
    error DirectEthTransferNotAllowed();
    error NotOwnerOfToken(uint256 tokenId, address owner);
    error TokenNotListed(uint256 tokenId);
    error RequestedConfirmationPeriodTooLong(uint256 period, uint256 maxPeriod);
    error RequestedConfirmationPeriodTooShort(uint256 period, uint256 minPeriod);
    error NotKYCVerified(address user);
    error NotAllowedToken(address token);
    error ZeroAmount();
    error NotInPendingSellerConfirmation(uint256 tokenId, PropertyStatus status);
    error PurchaseNonExistent(uint256 tokenId);
    error CallerNotSeller(uint256 tokenId, address caller, address seller);
    error PurchaseConfirmationPeriodExpired(uint256 tokenId, uint256 confirmationDeadline);
    error PurchaseConfirmationPeriodNotExpired(uint256 tokenId, uint256 confirmationDeadline);
    error CallerIsSeller(uint256 tokenId, address caller, address seller);
    error CannotListPropertyDueToNFTNotApproved(uint256 tokenId);
    error CannotCreatePendingPurchaseDueToInsufficientAllowance(
        address token, uint256 settlementPrice, uint256 allowance
    );
    error CannotCreatePendingPurchaseDueToInsufficientBalance(
        address token, uint256 settlementPrice, uint256 allowance, uint256 balance
    );
    error NotEnoughAllowanceOrBalanceToPlaceOffer(
        address token, uint128 offerAmount, uint256 allowance, uint256 balance
    );
    error OfferHasChanged(uint128 expectedAmount, uint128 actualAmount);
    error OfferExpired(uint256 tokenId, address offerFrom, uint64 expiredAt);
    error ListingNotChanged(uint256 tokenId);
    error InvalidToken();
    error EmergencyWithdrawAmountTooHigh();
    error OnlyAdminCanCall();
    error AdminControlMismatch(address passedAdminControl, address onNFT);
    error CallerNotSellerOrBuyer(uint256 tokenId, address caller, address seller, address buyer);
    error FeeMismatch(uint256 expectedFee, uint256 baseFee);
    error InvalidNFTCollection(address token);
    error UnexpectedERC721Transfer(address from, uint256 tokenId);
    error OnlyTokenWhitelistManagerCanCall();
    error NotNftPropertyManager();
    error OnlyProtocolParamManagerCanCall();
    error MinConfirmationPeriodTooHigh(uint256 newMinConfirmationPeriod, uint256 maxConfirmationPeriod);
    error MaxConfirmationPeriodTooLow(uint256 newMaxConfirmationPeriod, uint256 minConfirmationPeriod);
    error ListingHasBeenUpdated(uint256 currentListingVersion, uint256 expectedListingVersion);
    error OfferNotFound(uint256 tokenId, address from);
    error PurchaseNotAllowedWhileSellerIsReviewingOffers(uint256 tokenId);
    error NewOfferNotAllowedWhileSellerIsReviewingOffers(uint256 tokenId);
    error MustBeReviewingOffersToAcceptOffer(uint256 tokenId);
    error OfferFromNotKYCVerified(uint256 tokenId, address offerFrom);
    error OfferTTLTooLong(uint256 ttl, uint256 maxOfferTTL);
    error SellerAlreadyReviewingOffers(uint256 tokenId, address seller, uint256 reviewingOffersUntil);
    error SellerNotReviewingOffers(uint256 tokenId, address seller, uint256 reviewingOffersUntil);
    error UpdateNotAllowedWhileSellerIsReviewingOffers(uint256 tokenId);
    error CannotListInCurrentState(uint256 tokenId, PropertyStatus currentStatus);
    error Unescrowable(uint256 tokenId, address currentOwner);
    error newNFTContractHasDifferentAdminController(address adminControllerOnNftContract, address adminControl);
    //Modifiers

    /**
     * @dev Throws if called by any account other than the admin of the AdminControl contract.
     */
    modifier onlyAdmin() {
        if (!adminControl.hasRole(adminControl.DEFAULT_ADMIN_ROLE(), msg.sender)) {
            revert OnlyAdminCanCall();
        }
        _;
    }

    /**
     * @dev Throws if called by any account that does not have the NFT_PROPERTY_MANAGER_ROLE.
     */
    modifier onlyNftPropertyManager() {
        if (!adminControl.hasRole(adminControl.NFT_PROPERTY_MANAGER_ROLE(), msg.sender)) {
            revert NotNftPropertyManager();
        }
        _;
    }

    /**
     * @dev Throws if called by any account that does not have the PROTOCOL_PARAM_MANAGER_ROLE.
     */
    modifier onlyProtocolParamManager() {
        if (!adminControl.hasRole(adminControl.PROTOCOL_PARAM_MANAGER_ROLE(), msg.sender)) {
            revert OnlyProtocolParamManagerCanCall();
        }
        _;
    }

    /**
     * @dev Throws if called by any account that does not have the TOKEN_WHITELIST_MANAGER_ROLE.
     */
    modifier onlyTokenWhitelistManager() {
        if (!adminControl.hasRole(adminControl.TOKEN_WHITELIST_MANAGER_ROLE(), msg.sender)) {
            revert OnlyTokenWhitelistManagerCanCall();
        }
        _;
    }

    /**
     * @dev Throws if the caller is not KYC verified.
     */
    modifier onlyKYCVerified() {
        if (!adminControl.isKYCVerified(msg.sender)) {
            revert NotKYCVerified(msg.sender);
        }
        _;
    }

    /**
     * @dev Throws if the token is not in the list of allowed payment tokens.
     * @param token The address of the token to check.
     */
    modifier onlyAllowedToken(address token) {
        if (!allowedPaymentTokens[token]) {
            revert NotAllowedToken(token);
        }
        _;
    }

    /**
     * @dev Throws if the given amount is zero.
     * @param amount The amount to check.
     */
    modifier onlyNonZeroAmount(uint256 amount) {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _;
    }

    /**
     * @dev Throws if the caller is not the seller of the property.
     * @param tokenId The ID of the NFT.
     */
    modifier onlySellerCanCall(uint256 tokenId) {
        PropertyListing storage listing = listings[tokenId];
        if (listing.seller != msg.sender) {
            revert CallerNotSeller(tokenId, msg.sender, listing.seller);
        }
        _;
    }

    /**
     * @notice Modifier that checks if a function is paused in the AdminControl contract.
     * @param functionId The ID of the function to check.
     */
    modifier whenFunctionActive(bytes32 functionId) {
        adminControl.checkPaused(functionId);
        _;
    }

    //Constructor

    /**
     * @notice Initializes the PropertyMarket contract.
     * @param _manageLifePropertyNFT The address of the ManageLifePropertyNFT contract.
     * @param _adminControl The address of the AdminControl contract.
     */
    constructor(IManageLifePropertyNFT _manageLifePropertyNFT, IAdminControl _adminControl) RescueERC20Timelock(_adminControl){
        if (address(_manageLifePropertyNFT) == address(0)) {
            revert ZeroAddress();
        }
        if (address(_adminControl) == address(0)) {
            revert ZeroAddress();
        }
        address adminOnNFT = address(_manageLifePropertyNFT.adminController());
        if (adminOnNFT != address(_adminControl)) {
            revert AdminControlMismatch(address(_adminControl), adminOnNFT);
        }

        manageLifePropertyNFT = _manageLifePropertyNFT;
        adminControl = _adminControl;
        minConfirmationPeriod = 5 days; //defaults to 5 days
        maxConfirmationPeriod = 14 days; //defaults to 14 days
        maxOfferTTL = 90 days; //defaults to 90 days
        offerReviewPeriod = 1 days; //defaults to 1 day
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
    function addAllowedToken(address token) external onlyTokenWhitelistManager whenFunctionActive(adminControl.PROTOCOL_PARAM_CONFIGURATION()) {
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
    function removeAllowedToken(address token) external onlyTokenWhitelistManager whenFunctionActive(adminControl.PROTOCOL_PARAM_CONFIGURATION()) {
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
     * @dev The NFT is escrowed immediately upon listing and while pending seller confirmation; it’s released to the buyer on sale or returned to the seller on unlisting
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
        whenFunctionActive(LISTING_OPERATIONS)
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
    function unlistProperty(uint256 tokenId) external onlyKYCVerified onlySellerCanCall(tokenId) nonReentrant whenFunctionActive(LISTING_OPERATIONS) {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        listing.status = PropertyStatus.DELISTED;

        manageLifePropertyNFT.safeTransferFrom(address(this), msg.sender, tokenId);

        emit PropertyUnlisted(tokenId, msg.sender, listingVersions[tokenId]);
    }

    /**
     * @notice Updates the price and/or payment token of a listing by an admin.
     * @dev This will invalidate all existing offers on the property.
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
        whenFunctionActive(LISTING_OPERATIONS)
    {
        _updateListing(tokenId, newPrice, newPaymentToken);
    }

    /**
     * @notice Updates the price and/or payment token of a listing by the seller.
     * @notice Doesn't need reentrancy, but it's there to prevent cross-function reentrancy.
     * @dev This will invalidate all existing offers on the property.
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
        whenFunctionActive(LISTING_OPERATIONS)
    {
        _updateListing(tokenId, newPrice, newPaymentToken);
    }

    //Step 2: Non-Offer Purchases, called by buyers that don't want to offer and just buy at listing price.

    /**
     * @notice Initiates a purchase of a property at its current listing price.
     * @dev This creates a pending purchase and escrows the buyer's funds. The seller must confirm the purchase.
     * @param tokenId The ID of the NFT to purchase.
     * @param expectedFee The expected protocol fee percentage, used for front-run protection.
     * @param expectedListingVersion The expected version of the listing, for front-run protection.
     */
    function purchasePropertyAtListingPrice(uint256 tokenId, uint256 expectedFee, uint256 expectedListingVersion)
        external
        nonReentrant
        onlyKYCVerified
        whenFunctionActive(PURCHASE_OPERATIONS)
    {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        if (block.timestamp < listing.reviewingOffersUntil) {
            revert PurchaseNotAllowedWhileSellerIsReviewingOffers(tokenId);
        }
        //Front run protection from listing updates.
        if (expectedListingVersion != listingVersions[tokenId]) {
            revert ListingHasBeenUpdated(expectedListingVersion, listingVersions[tokenId]);
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
    function confirmPurchase(uint256 tokenId) external nonReentrant onlySellerCanCall(tokenId) onlyKYCVerified whenFunctionActive(PURCHASE_OPERATIONS) {
        (PropertyListing storage listing, PendingPurchase storage purchase) = _performPendingPurchaseChecks(tokenId);

        //Send the NFT to buyer,  because it's escrowed already.
        _processNFTTransfer(tokenId, purchase.buyer);

        //Send escrowed tokens to seller
        _processPropertyTokenPayment(listing, purchase, tokenId);

        listing.status = PropertyStatus.SOLD;
        delete pendingPurchases[tokenId];

        emit PropertySold(
            tokenId,
            purchase.buyer,
            listing.seller,
            purchase.price,
            purchase.paymentToken,
            purchase.purchaseType,
            listingVersions[tokenId]
        );
    }

    /**
     * @notice Rejects a pending purchase.
     * @dev The buyer's escrowed funds are returned. The property is returned to the LISTED state.
     * @dev If the purchase was from an offer, that offer is removed.
     * @dev Can only be called by the seller (KYC'd) before the confirmation period expires.
     * @param tokenId The ID of the NFT.
     */
    function rejectPurchase(uint256 tokenId) external onlySellerCanCall(tokenId) nonReentrant onlyKYCVerified {
        (PropertyListing storage listing, PendingPurchase storage purchase) = _performPendingPurchaseChecks(tokenId);

        _refundPendingPurchaseTokens(tokenId); //This undoes the escrow of the purchase token.

        emit PurchaseRejected(
            tokenId, msg.sender, purchase.buyer, purchase.price, purchase.paymentToken, purchase.purchaseType
        );

        delete pendingPurchases[tokenId]; //Delete the purchase from the pending purchases map.
        listing.status = PropertyStatus.LISTED; //Back to listed state.
    }

    //Step 4: Offers
    /**
     * @notice Places an offer for a listed property.
     * @dev The caller must be KYC verified and have sufficient allowance and balance of the payment token.
     * @dev A new offer cannot be placed while the seller is reviewing offers.
     * @dev The seller cannot place an offer on their own property.
     * @dev The offer can be lower or higher than the listing price.
     * @param tokenId The ID of the NFT to place an offer for.
     * @param offerAmount The amount of the offer.
     * @param expectedListingVersion The expected version of the listing, for front-run protection.
     * @param ttl The time-to-live for the offer in seconds. If 0, the offer does not expire.
     */
    function placeOffer(uint256 tokenId, uint128 offerAmount, uint256 expectedListingVersion, uint64 ttl)
        external
        onlyKYCVerified
        onlyNonZeroAmount(offerAmount)
        nonReentrant
        whenFunctionActive(OFFER_OPERATIONS)
    {
        PropertyListing storage listing = listings[tokenId];
        IERC20 paymentToken = IERC20(listing.paymentToken);
        uint256 currentListingVersion = listingVersions[tokenId];

        //Front run protection
        if (currentListingVersion != expectedListingVersion) {
            revert ListingHasBeenUpdated(currentListingVersion, expectedListingVersion);
        }

        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        if (block.timestamp < listing.reviewingOffersUntil) {
            revert NewOfferNotAllowedWhileSellerIsReviewingOffers(tokenId);
        }

        if (listing.seller == msg.sender) {
            revert CallerIsSeller(tokenId, msg.sender, listing.seller);
        }

        if (ttl > maxOfferTTL) {
            revert OfferTTLTooLong(ttl, maxOfferTTL);
        }

        // Check that the contract is allowed to transfer tokens on behalf of the buyer
        uint256 allowance = paymentToken.allowance(msg.sender, address(this));
        uint256 balance = paymentToken.balanceOf(msg.sender);
        if (allowance < offerAmount || balance < offerAmount) {
            revert NotEnoughAllowanceOrBalanceToPlaceOffer(listing.paymentToken, offerAmount, allowance, balance);
        }

        Offer storage offer = offers[tokenId][msg.sender];
        bool isNewOffer = offer.timestamp == 0;
        offer.amount = offerAmount;
        offer.forListingVersion = expectedListingVersion;
        offer.timestamp = uint64(block.timestamp);
        if (ttl > 0) {
            uint256 exp = block.timestamp + ttl;
            if (exp > type(uint64).max) {
                offer.validUntil = 0; //Admin has set up a very high max ttl, so we can't use it, default to 0.
            } else {
                offer.validUntil = uint64(exp);
            }
        } else {
            offer.validUntil = 0;
        }

        emit OfferPlaced(
            tokenId,
            msg.sender,
            offerAmount,
            listing.paymentToken,
            offer.forListingVersion,
            offer.validUntil,
            isNewOffer
        );
    }

    /**
     * @notice Withdraws an offer made by the caller for a property.
     * @dev An offer can be withdrawn at any time before it is accepted.
     * @param tokenId The ID of the NFT for which the offer was made.
     */
    //Can withdraw offer in any state, it's just cleanup.
    function withdrawOffer(uint256 tokenId) external nonReentrant {
        Offer storage offer = offers[tokenId][msg.sender];
        if (offer.timestamp == 0) {
            revert OfferNotFound(tokenId, msg.sender);
        }
        emit OfferWithdraw(tokenId, msg.sender, offer.amount, offer.forListingVersion);
        delete offers[tokenId][msg.sender];
    }

    /**
     * @notice Allows the seller to enter a state of reviewing offers for a property.
     * @dev When in this state, no new offers or "buy it now" purchases can be made.
     * @dev This state lasts for the duration of the offer review period, offerReviewPeriod, then it turns off automatically.
     * @dev The seller can accept an offer during this period.
     * @param tokenId The ID of the NFT.
     */
    function startReviewingOffersStatus(uint256 tokenId)
        external
        onlySellerCanCall(tokenId)
        nonReentrant
        onlyKYCVerified
        whenFunctionActive(OFFER_OPERATIONS)
    {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }

        if (block.timestamp <= listing.reviewingOffersUntil) {
            revert SellerAlreadyReviewingOffers(tokenId, msg.sender, listing.reviewingOffersUntil);
        }

        listing.reviewingOffersUntil = block.timestamp + offerReviewPeriod;
        emit SellerReviewingOffersForListingUntil(
            tokenId, msg.sender, listing.reviewingOffersUntil, listingVersions[tokenId]
        );
    }

    /**
     * @notice Allows the seller to exit the state of reviewing offers.
     * @dev This allows new offers and "buy it now" purchases to be made again.
     * @param tokenId The ID of the NFT.
     */
    function stopReviewingOffers(uint256 tokenId) external onlySellerCanCall(tokenId) nonReentrant onlyKYCVerified {
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        if (block.timestamp > listing.reviewingOffersUntil) {
            revert SellerNotReviewingOffers(tokenId, msg.sender, listing.reviewingOffersUntil);
        }
        listing.reviewingOffersUntil = 0;
        emit SellerNoLongerReviewingOffersForListing(tokenId, msg.sender, listingVersions[tokenId]);
    }

    /**
     * @notice Accepts an offer for a property.
     * @dev Can only be called by the seller while the listing is in the "reviewing offers" state, for front-run protection.
     * @dev The offer must be valid (not expired) and for the current listing version.
     * @dev The offerer must be KYC verified.
     * @dev This creates a pending purchase, which the seller must then confirm.
     * @param tokenId The ID of the NFT.
     * @param offerFrom The address of the user who made the offer.
     * @param expectedOfferAmount The expected amount of the offer, for front-run protection.
     * @param expectedFee The expected protocol fee, for front-run protection.
     */
    function acceptOffer(uint256 tokenId, address offerFrom, uint128 expectedOfferAmount, uint256 expectedFee)
        external
        nonReentrant
        onlySellerCanCall(tokenId)
        onlyKYCVerified
        whenFunctionActive(OFFER_OPERATIONS)
    {
        PropertyListing storage listing = listings[tokenId];
        if (block.timestamp >= listing.reviewingOffersUntil) {
            revert MustBeReviewingOffersToAcceptOffer(tokenId);
        }
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        Offer storage offer = offers[tokenId][offerFrom];
        if (offer.timestamp == 0) {
            revert OfferNotFound(tokenId, offerFrom);
        }

        if (offer.validUntil > 0 && offer.validUntil < block.timestamp) {
            revert OfferExpired(tokenId, offerFrom, offer.validUntil);
        }

        if (offer.forListingVersion != listingVersions[tokenId]) {
            revert ListingHasBeenUpdated(listingVersions[tokenId], offer.forListingVersion);
        }

        if (!adminControl.isKYCVerified(offerFrom)) {
            revert OfferFromNotKYCVerified(tokenId, offerFrom);
        }

        //Front run protection
        if (offer.amount != expectedOfferAmount) {
            revert OfferHasChanged(expectedOfferAmount, offer.amount);
        }

        _createPendingPurchase(tokenId, offer.amount, listing.paymentToken, offerFrom, expectedFee, PurchaseType.OFFER);
        uint128 offerAmount = offer.amount;
        uint256 forListingVersion = offer.forListingVersion;
        delete offers[tokenId][offerFrom]; //Delete the offer, has been accepted and processed.
        emit OfferAccepted(tokenId, listing.seller, offerFrom, offerAmount, listing.paymentToken, forListingVersion);
    }

    /**
     * @notice Cancels a pending purchase that has passed its confirmation deadline, callable by seller or buyer.
     * @dev Returns the escrowed funds to the buyer and puts the property back into the LISTED state.
     * @dev Can be called by either the seller or the buyer of the expired purchase.
     * @dev Non-KYC in the case that the buyer or seller become non KYC'd, at least they can always cancel the expired purchase.
     * @param tokenId The ID of the NFT with the expired purchase.
     */
    function cancelExpiredPurchase(uint256 tokenId) external nonReentrant {
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
    function setMinConfirmationPeriod(uint256 newMinConfirmationPeriod)
        external
        onlyProtocolParamManager
        onlyNonZeroAmount(newMinConfirmationPeriod)
        whenFunctionActive(adminControl.PROTOCOL_PARAM_CONFIGURATION())
    {
        if (newMinConfirmationPeriod > maxConfirmationPeriod) {
            revert MinConfirmationPeriodTooHigh(newMinConfirmationPeriod, maxConfirmationPeriod);
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
    function setMaxConfirmationPeriod(uint256 newMaxConfirmationPeriod) external onlyProtocolParamManager whenFunctionActive(adminControl.PROTOCOL_PARAM_CONFIGURATION()) {
        if (newMaxConfirmationPeriod < minConfirmationPeriod) {
            revert MaxConfirmationPeriodTooLow(newMaxConfirmationPeriod, minConfirmationPeriod);
        }
        uint256 oldMaxConfirmationPeriod = maxConfirmationPeriod;
        maxConfirmationPeriod = newMaxConfirmationPeriod;
        emit MaxConfirmationPeriodSet(oldMaxConfirmationPeriod, newMaxConfirmationPeriod);
    }

    /**
     * @notice Sets the maximum time-to-live for new offers.
     * @dev Can only be called by an account with the PROTOCOL_PARAM_MANAGER_ROLE.
     * @param newMaxOfferTTL The new maximum TTL in seconds.
     */
    function setMaxOfferTTL(uint256 newMaxOfferTTL)
        external
        onlyProtocolParamManager
        onlyNonZeroAmount(newMaxOfferTTL)
        whenFunctionActive(adminControl.PROTOCOL_PARAM_CONFIGURATION())
    {
        uint256 oldMaxOfferTTL = maxOfferTTL;
        maxOfferTTL = newMaxOfferTTL;
        emit MaxOfferTTLSet(oldMaxOfferTTL, newMaxOfferTTL);
    }

    /**
     * @notice Sets the duration for the offer review period.
     * @dev Can only be called by an account with the PROTOCOL_PARAM_MANAGER_ROLE.
     * @dev This should be long enough to allow the seller to review offers and accept or reject them.
     * @param newOfferReviewPeriod The new duration in seconds.
     */
    function setOfferReviewPeriod(uint256 newOfferReviewPeriod)
        external
        onlyProtocolParamManager
        onlyNonZeroAmount(newOfferReviewPeriod)
        whenFunctionActive(adminControl.PROTOCOL_PARAM_CONFIGURATION())
    {
        uint256 oldOfferReviewPeriod = offerReviewPeriod;
        offerReviewPeriod = newOfferReviewPeriod;
        emit OfferReviewPeriodSet(oldOfferReviewPeriod, newOfferReviewPeriod);
    }

    function setManageLifePropertyNFTContract(IManageLifePropertyNFT newPropertyNFTContract) external onlyAdmin whenFunctionActive(adminControl.PROTOCOL_WIRING_CONFIGURATION()) {
        if (address(newPropertyNFTContract) == address(0)) {
            revert ZeroAddress();
        }

        // Ensure the NFT contract's admin controller matches this controller's admin controller.
        address adminControllerOnNftContract = address(newPropertyNFTContract.adminController());
        if (adminControllerOnNftContract != address(adminControl)) {
            revert newNFTContractHasDifferentAdminController(adminControllerOnNftContract, address(adminControl));
        }

        address oldManageLifePropertyNFTContract = address(manageLifePropertyNFT);
        manageLifePropertyNFT = newPropertyNFTContract;
        emit ManageLifePropertyNFTContractUpdated(oldManageLifePropertyNFTContract, address(newPropertyNFTContract));
    }

    function setAdminControl(IAdminControl newAdminControl) external onlyAdmin whenFunctionActive(adminControl.PROTOCOL_WIRING_CONFIGURATION()) {
        if (address(newAdminControl) == address(0)) {
            revert ZeroAddress();
        }
        address oldAdminControl = address(adminControl);
        adminControl = newAdminControl;
        emit AdminControlUpdated(oldAdminControl, address(newAdminControl));
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
     * @return reviewingOffersUntil The timestamp until which the seller is reviewing offers.
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
            uint256 reviewingOffersUntil
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
            listing.reviewingOffersUntil
        );
    }

    //ERC721Receiver interface

    /**
     * @notice Handles the receipt of an NFT.
     * @dev This function is part of the ERC721 standard. It ensures that NFTs are only
     * accepted into this contract as part of the `listProperty` flow.
     * @dev Note: Compiler warns this could be `view`, but it cannot due to ERC721Receiver interface inheritance requirements.
     * @param from The address which sent the NFT.
     * @param tokenId The ID of the NFT.
     * @return A selector indicating that the contract can receive ERC721 tokens.
     */
    // solhint-disable-next-line func-mutability
    function onERC721Received(
        address,
        /* operator */
        address from,
        uint256 tokenId,
        bytes memory /* data */
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

    /**
     * @notice Creates a new property listing and escrows the NFT to this contract.
     * @dev This function handles the core listing logic with the following steps:
     *      1. Validates the caller owns the NFT
     *      2. Asserts no active listing or pending purchase for this token (invariant check)
     *      3. Clears any stale listing data and creates fresh listing
     *      4. Validates NFT approval for transfer
     *      5. Transfers NFT to escrow and emits listing event
     *
     * @dev Ownership validation: The function relies on NFT ownership as the primary validation.
     *      If a user owns the NFT, it cannot be in escrow, which means any previous listing
     *      must be inactive. This eliminates the need for complex state checks.
     *
     * @dev Escrow mechanism: The NFT is immediately transferred to this contract upon listing,
     *      ensuring the marketplace has custody during the entire sale process. This prevents
     *      sellers from transferring or relisting the NFT while a sale is active.
     *
     * @param tokenId The ID of the NFT to list for sale.
     * @param price The listing price in the specified payment token.
     * @param paymentToken The ERC20 token address accepted for payment.
     * @param period The confirmation period (in seconds) for purchase confirmations.
     *
     * @dev Requirements:
     *      - Caller must own the NFT (checked via ownerOf)
     *      - NFT must not be in active listing or pending confirmation (invariant)
     *      - This contract must be approved to transfer the NFT
     *      - All parameters must be valid (validated by calling function)
     *
     * @dev Effects:
     *      - Clears any existing listing data for the tokenId
     *      - Creates new PropertyListing with LISTED status
     *      - Transfers NFT from owner to this contract (escrow)
     *      - Emits NewListing event
     */
    function _listPropertyWithConfirmation(uint256 tokenId, uint128 price, address paymentToken, uint64 period)
        internal
    {
        address currentOwner = manageLifePropertyNFT.ownerOf(tokenId);
        uint256 currentVersion = listingVersions[tokenId];
        if (currentOwner != msg.sender) {
            revert NotOwnerOfToken(tokenId, currentOwner);
        }
        PropertyListing storage existingListing = listings[tokenId];

        // Should never happen. The NFT is escrowed, so it cannot be listed twice.
        if (
            existingListing.status == PropertyStatus.LISTED
                || existingListing.status == PropertyStatus.PENDING_SELLER_CONFIRMATION
        ) {
            revert CannotListInCurrentState(tokenId, existingListing.status);
        }

        // A check for a previous listing by a different owner is not necessary.
        // For a new owner to list the NFT, they must hold it, which means it cannot be
        // in escrow from a previous `LISTED` or `PENDING_SELLER_CONFIRMATION` state.
        // Any previous listing data from a different owner is therefore considered stale
        // and will be safely overwritten by the new listing.

        // Similarly, checks to prevent the current owner from re-listing an already active
        // listing are also redundant. If the listing were active, the contract would hold
        // the NFT, and the initial ownership check on this function would have failed.
        // Therefore, we can proceed directly to creating the new listing.

        // Fresh listing for token
        delete listings[tokenId]; // Delete old listing data
        PropertyListing storage listing = listings[tokenId];
        listing.seller = msg.sender;
        listing.price = price;
        listing.paymentToken = paymentToken;
        listing.status = PropertyStatus.LISTED;
        listing.listTimestamp = uint64(block.timestamp);
        listing.lastRenewed = uint64(block.timestamp);
        listing.confirmationPeriod = period;

        if (
            !manageLifePropertyNFT.isApprovedForAll(msg.sender, address(this))
                && manageLifePropertyNFT.getApproved(tokenId) != address(this)
        ) {
            revert CannotListPropertyDueToNFTNotApproved(tokenId);
        }

        //Increase the version of the listing.
        listingVersions[tokenId] = currentVersion + 1;

        // Move the NFT to this contract (escrow) when listing
        manageLifePropertyNFT.safeTransferFrom(msg.sender, address(this), tokenId);

        emit NewListing(tokenId, msg.sender, price, paymentToken, period, listingVersions[tokenId]);
    }

    /**
     * @notice Creates a pending purchase by escrowing the buyer's payment tokens and setting up confirmation period.
     * @dev This function transitions a listing to PENDING_SELLER_CONFIRMATION status and performs the following:
     *      1. Updates listing status and calculates confirmation deadline
     *      2. Retrieves current fee configuration with protection against fee-changes.
     *      3. Creates the pending purchase record with all relevant data
     *      4. Validates buyer's token allowance and balance for the settlement amount
     *      5. Escrows the buyer's payment tokens to this contract
     *
     * @dev Fee protection: The expectedFee parameter prevents front-running attacks where admins
     *      could change fees between transaction submission and execution. The transaction will
     *      revert if the current fee doesn't match the expected fee.
     *
     * @param tokenId The ID of the NFT being purchased.
     * @param settlementPrice The agreed purchase price (listing price or accepted offer amount).
     * @param paymentToken The ERC20 token address used for payment.
     * @param buyer The address of the buyer making the purchase.
     * @param expectedFee The expected protocol fee percentage for fee-change protection.
     * @param purchaseType Whether this is from a direct listing purchase or accepted offer.
     *
     * @dev Requirements:
     *      - Listing must exist and be in LISTED status (validated by caller)
     *      - Buyer must have sufficient token allowance and balance for settlementPrice
     *      - Current protocol fee must match expectedFee
     *
     * @dev Effects:
     *      - Changes listing status to PENDING_SELLER_CONFIRMATION
     *      - Creates pendingPurchases[tokenId] record
     *      - Transfers settlementPrice tokens from buyer to this contract (escrow)
     *      - Emits PurchaseRequested event
     */
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
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig(); //Fee should be fetched at this stage to prevent malicious changing at settlement time.

        if (baseFee != expectedFee) {
            revert FeeMismatch(expectedFee, baseFee);
        }

        uint256 allowance = token.allowance(buyer, address(this));
        uint256 balance = token.balanceOf(buyer);

        if (balance < settlementPrice) {
            revert CannotCreatePendingPurchaseDueToInsufficientBalance(
                address(token), settlementPrice, allowance, balance
            );
        }
        if (allowance < settlementPrice) {
            revert CannotCreatePendingPurchaseDueToInsufficientAllowance(address(token), settlementPrice, allowance);
        }
        uint256 deadline = block.timestamp + listing.confirmationPeriod;
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
        listing.status = PropertyStatus.PENDING_SELLER_CONFIRMATION; //Now entering the escrow phase. We can safely escrow the tokens because this is called by the buyer.

        token.safeTransferFrom(buyer, address(this), settlementPrice); //Buyer sends tokens to escrow.

        emit PurchaseRequested(
            tokenId,
            buyer,
            settlementPrice,
            paymentToken,
            uint64(deadline),
            purchaseType,
            baseFee,
            feeCollector,
            listingVersions[tokenId]
        );
    }

    /**
     * @notice Validates all conditions for processing a pending purchase and returns the storage references.
     * @dev Performs comprehensive validation checks before allowing purchase confirmation or rejection:
     *      1. Verifies pending purchase exists (non-zero paymentToken address)
     *      2. Confirms listing is in PENDING_SELLER_CONFIRMATION status
     *      3. Asserts this contract owns the NFT (escrow validation, invariant check)
     *      4. Ensures confirmation deadline has not expired
     *
     * @param tokenId The ID of the NFT with the pending purchase to validate.
     * @return listing Storage reference to the property listing.
     * @return purchase Storage reference to the pending purchase data.
     *
     * @dev Requirements:
     *      - Pending purchase must exist for the given tokenId
     *      - Listing status must be PENDING_SELLER_CONFIRMATION
     *      - This contract must own the NFT (in escrow)
     *      - Current timestamp must be within the confirmation deadline
     */
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

        //Should never happen, as the token is supposed to be escrowed in this contract.
        address currentOwner = manageLifePropertyNFT.ownerOf(tokenId);
        if (currentOwner != address(this)) {
            revert Unescrowable(tokenId, currentOwner);
        }

        if (block.timestamp > purchase.confirmationDeadline) {
            revert PurchaseConfirmationPeriodExpired(tokenId, purchase.confirmationDeadline);
        }
        return (listing, purchase);
    }

    /**
     * @notice Refunds the escrowed payment tokens to the buyer when a purchase is rejected or expires.
     * @dev Retrieves the pending purchase details and transfers the full escrowed amount back to the buyer.
     *      This function releases the payment tokens that were held in escrow during the confirmation period.
     * @param tokenId The ID of the NFT with the pending purchase to refund.
     */
    function _refundPendingPurchaseTokens(uint256 tokenId) internal {
        PendingPurchase storage purchase = pendingPurchases[tokenId];
        IERC20 token = IERC20(purchase.paymentToken);
        token.safeTransfer(purchase.buyer, purchase.price);
    }

    /**
     * @notice Processes the payment distribution for a completed property sale.
     * @dev Calculates and distributes the escrowed payment tokens between the seller (net amount)
     *      and protocol (fees). Uses the PERCENTAGE_BASE constant for fee calculations.
     * @param listing The listing object.
     * @param purchase The purchase object.
     * @param tokenId The ID of the NFT.
     */
    function _processPropertyTokenPayment(
        PropertyListing storage listing,
        PendingPurchase storage purchase,
        uint256 tokenId
    ) internal {
        IERC20 token = IERC20(purchase.paymentToken);

        uint256 fees = 0;
        uint256 netValue = purchase.price;
        if (purchase.fee > 0 && purchase.feeCollector != address(0)) {
            fees = (purchase.price * purchase.fee) / PERCENTAGE_BASE;
            netValue = purchase.price - fees;
        }

        token.safeTransfer(listing.seller, netValue);

        if (fees > 0) {
            token.safeTransfer(purchase.feeCollector, fees);
        }

        emit PaymentProcessed(
            tokenId,
            listing.seller,
            purchase.price,
            fees,
            purchase.paymentToken,
            purchase.feeCollector,
            listingVersions[tokenId]
        );
    }

    /**
     * @notice Transfers the escrowed NFT to the buyer.
     * @dev The NFT is held in escrow by this contract and is released upon confirmed purchase.
     * @param tokenId The ID of the NFT to transfer.
     * @param buyer The address receiving the NFT.
     */
    function _processNFTTransfer(uint256 tokenId, address buyer) internal {
        // NFT is escrowed, transfer it from escrow to the buyer
        manageLifePropertyNFT.safeTransferFrom(address(this), buyer, tokenId, "");
    }

    /**
     * @notice Internal function to update a listing's price and/or payment token.
     * @dev This will invalidate all existing offers on the property by incrementing the listing version.
     * @param tokenId The ID of the NFT to update.
     * @param newPrice The new listing price.
     * @param newPaymentToken The new ERC20 payment token.
     */
    function _updateListing(uint256 tokenId, uint128 newPrice, address newPaymentToken) internal {
        uint256 currentVersion = listingVersions[tokenId];
        PropertyListing storage listing = listings[tokenId];
        if (listing.status != PropertyStatus.LISTED) {
            revert TokenNotListed(tokenId);
        }
        if (block.timestamp < listing.reviewingOffersUntil) {
            revert UpdateNotAllowedWhileSellerIsReviewingOffers(tokenId);
        }
        if (listing.paymentToken == newPaymentToken && listing.price == newPrice) {
            revert ListingNotChanged(tokenId);
        }

        if (listing.paymentToken != newPaymentToken) {
            emit ListingTokenChanged(tokenId, listing.paymentToken, newPaymentToken, msg.sender, currentVersion + 1);
            listing.paymentToken = newPaymentToken;
        }
        if (listing.price != newPrice) {
            emit ListingPriceChanged(tokenId, listing.price, newPrice, msg.sender, currentVersion + 1);
            listing.price = newPrice;
        }
        listingVersions[tokenId] = currentVersion + 1;
        listing.lastRenewed = uint64(block.timestamp);
    }
}
