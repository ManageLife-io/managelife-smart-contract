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
    constructor(address _nfti, address _nftm, AdminControl _adminControl){
        require(_nfti != address(0), ErrorCodes.E001);
        require(_nftm != address(0), ErrorCodes.E001);

        nftiContract = IERC721(_nfti);
        nftmContract = IERC721(_nftm);
        adminControl = _adminControl;
    }

    uint256 public constant PERCENTAGE_BASE = 10000;

    enum PropertyStatus { LISTED, SOLD, DELISTED, PENDING_SELLER_CONFIRMATION }

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

    event EmergencyTokenWithdrawal(address indexed token, address indexed recipient, uint256 amount);
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


    error DirectEthTransferNotAllowed();

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
    
    function listProperty(uint256 tokenId, uint256 price, address paymentToken) external nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(price) {
        _listPropertyWithConfirmation(tokenId, price, paymentToken, 0);
    }

    function listPropertyWithConfirmation(uint256 tokenId, uint256 price, address paymentToken, uint256 period) external nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(price) {
        require(period <= 7 days, ErrorCodes.E607);
        _listPropertyWithConfirmation(tokenId, price, paymentToken, period);
    }
    function _listPropertyWithConfirmation(uint256 tokenId, uint256 price, address paymentToken, uint256 period) internal {
        address currentOwner = nftiContract.ownerOf(tokenId);
        require(currentOwner == msg.sender, ErrorCodes.E105);
        PropertyListing storage existingListing = listings[tokenId];

        if (existingListing.seller != address(0) && existingListing.seller != currentOwner) {
            if (existingListing.status == PropertyStatus.LISTED) {
                _cancelAllBids(tokenId);
            }
        } else if (existingListing.seller == currentOwner) {
            require(existingListing.status != PropertyStatus.LISTED, ErrorCodes.E102);
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
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E101);
        require(_validatePayment(listing.price, offerPrice, listing.paymentToken, tokenId), ErrorCodes.E005);
        uint256 highestBid = _getHighestActiveBid(tokenId);
        uint256 actualPrice = highestBid > 0 ? offerPrice : listing.price;
        if (listing.confirmationPeriod > 0) {
            _createPendingPurchase(tokenId, actualPrice, listing.paymentToken);
        } else {
            _completePurchase(tokenId, actualPrice, listing.paymentToken, highestBid);
        }
    }
    function _createPendingPurchase(uint256 tokenId, uint256 actualPrice, address paymentToken) internal {
        PropertyListing storage listing = listings[tokenId];
        IERC20 token = IERC20(paymentToken);
        token.safeTransferFrom(msg.sender, address(this), actualPrice);
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

        require(listing.status == PropertyStatus.PENDING_SELLER_CONFIRMATION, ErrorCodes.E602);
        require(purchase.isActive, ErrorCodes.E603);
        require(nftiContract.ownerOf(tokenId) == msg.sender, ErrorCodes.E604);
        require(block.timestamp <= purchase.confirmationDeadline, ErrorCodes.E605);

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

        require(listing.status == PropertyStatus.PENDING_SELLER_CONFIRMATION, ErrorCodes.E602);
        require(purchase.isActive, ErrorCodes.E603);
        require(block.timestamp > purchase.confirmationDeadline, ErrorCodes.E606);
        _refundPendingPurchase(tokenId);
        purchase.isActive = false;
        listing.status = PropertyStatus.LISTED;

        emit PurchaseExpired(tokenId, purchase.buyer, purchase.offerPrice, purchase.paymentToken);
    }
    function _refundPendingPurchase(uint256 tokenId) internal {
        PendingPurchase storage purchase = pendingPurchases[tokenId];
        IERC20 token = IERC20(purchase.paymentToken);
        token.safeTransfer(purchase.buyer, purchase.offerPrice);
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

    function _refundBid(address bidder, uint256 amount, address paymentToken, uint256) private {
        IERC20(paymentToken).safeTransfer(bidder, amount);
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
        uint256 minimumPrice = highestBid > 0 ? highestBid : listedPrice;
        return offerPrice >= minimumPrice;
    }

    function _processPayment(
        address seller,
        address buyer,
        uint256 amount,
        address paymentToken
    ) internal {
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig();
        PaymentProcessor.PaymentConfig memory config = PaymentProcessor.PaymentConfig({
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
    function updateListing(uint256 tokenId, uint256 newPrice, address newPaymentToken) external onlyAdminControlAdmin {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        require(newPrice > 0, ErrorCodes.E104);
        require(isTokenAllowed(newPaymentToken), ErrorCodes.E301);

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
    }


    modifier onlyAdminControlAdmin(){
        require(adminControl.hasRole(adminControl.DEFAULT_ADMIN_ROLE(), msg.sender), ErrorCodes.E401);
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        require(nftiContract.ownerOf(tokenId) == msg.sender, ErrorCodes.E002);
        _;
    }

    modifier onlyKYCVerified() {
        require(adminControl.isKYCVerified(msg.sender), ErrorCodes.E403);
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
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);

        address currentOwner = nftiContract.ownerOf(tokenId);
        require(currentOwner != msg.sender, ErrorCodes.E002);
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];
        if (existingBidIndex > 0) {
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            require(existingBid.isActive, ErrorCodes.E202);
            require(existingBid.paymentToken == paymentToken, ErrorCodes.E302);

            uint256 oldAmount = existingBid.amount;
            require(bidAmount > oldAmount, ErrorCodes.E205);
            uint256 additionalAmount = bidAmount - oldAmount;
            IERC20 token = IERC20(paymentToken);
            require(token.allowance(msg.sender, address(this)) >= additionalAmount, ErrorCodes.E208);
            token.safeTransferFrom(msg.sender, address(this), additionalAmount);

        } else {
            IERC20 token = IERC20(paymentToken);
            require(token.allowance(msg.sender, address(this)) >= bidAmount, ErrorCodes.E208);
            token.safeTransferFrom(msg.sender, address(this), bidAmount);
        }

        require(bidAmount >= listing.price, ErrorCodes.E206);
        uint256 highestBid = 0;
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].amount > highestBid) {
                highestBid = bids[i].amount;
            }
        }

        if (highestBid > 0) {
            uint256 minBid = highestBid;
            require(bidAmount >= minBid, ErrorCodes.E205);
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
        _processPaymentFromBalance(listing.seller, bid.amount, bid.paymentToken);
        nftiContract.safeTransferFrom(listing.seller, bid.bidder, tokenId, "");
        emit BidAccepted(tokenId, listing.seller, bid.bidder, bid.amount, bid.paymentToken);
        
        _cancelOtherBids(tokenId, bid.bidder);
    }

    function _calculateMinimumIncrement(uint256 currentHighest, uint256 /* newBid */) private pure returns (uint256) {
        uint256 incrementPercent;
        if (currentHighest < 1 ether) {
            incrementPercent = 10;
        } else if (currentHighest < 10 ether) {
            incrementPercent = 5;
        } else {
            incrementPercent = 2;
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

    function updateListingBySeller(uint256 tokenId, uint256 newPrice, address newPaymentToken) external onlyValidAmount(newPrice) onlyAllowedToken(newPaymentToken) {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, ErrorCodes.E103);
        require(nftiContract.ownerOf(tokenId) == msg.sender, ErrorCodes.E105);

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

    function emergencyWithdrawToken(address token, uint256 amount, address recipient) onlyAdminControlAdmin() external {
        require(token != address(0), ErrorCodes.E915);
        require(recipient != address(0), ErrorCodes.E913);

        IERC20 tokenContract = IERC20(token);
        require(amount <= tokenContract.balanceOf(address(this)), ErrorCodes.E916);

        tokenContract.safeTransfer(recipient, amount);

        emit EmergencyTokenWithdrawal(token, recipient, amount);
    }

    //We don't want to allow direct eth transfers to the contract
    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }

}
