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

contract PropertyMarket is ReentrancyGuard, AdminControl {
    constructor(address _nfti, address _nftm, address admin, address fee, address vault) AdminControl(admin, fee, vault) {
        require(_nfti != address(0), ErrorCodes.E001);
        require(_nftm != address(0), ErrorCodes.E001);

        allowedPaymentTokens[address(0)] = true;
        nftiContract = IERC721(_nfti);
        nftmContract = IERC721(_nftm);
    }

    receive() external payable {}

    uint256 public constant PERCENTAGE_BASE = 10000;

    enum PropertyStatus { LISTED, RENTED, SOLD, DELISTED, PENDING_PAYMENT, PENDING_SELLER_CONFIRMATION }

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

    uint32 public constant PAYMENT_TIMEOUT = 24 hours;
    mapping(uint256 => uint32) public paymentDeadlines;
    mapping(address => bool) public isDeflationaryToken;

    mapping(uint256 => Bid[]) public bidsForToken;
    mapping(uint256 => mapping(address => uint256)) public ethBidDeposits;
    mapping(address => mapping(uint256 => uint256)) public bidIndexByBidder;
    mapping(address => uint256) public pendingRefunds;
    mapping(address => mapping(address => uint256)) public pendingTokenRefunds;
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

    event EmergencyWithdrawal(address indexed recipient, uint256 amount);
    event EmergencyTokenWithdrawal(address indexed token, address indexed recipient, uint256 amount);
    event TimelockSet(address indexed timelock);
    event MultiSigOperatorSet(address indexed multiSigOperator);
    event TimelockEnabledChanged(bool enabled);
    event RefundQueued(address indexed user, uint256 amount);
    event RefundWithdrawn(address indexed user, uint256 amount);
    event CompetitivePurchase(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 purchasePrice,
        uint256 highestBidOutbid,
        address paymentToken
    );
    event BidRefundFailed(uint256 indexed tokenId, address indexed bidder, uint256 amount);
    event PaymentExpired(uint256 indexed tokenId, address indexed bidder, uint256 amount);
    event DeflationaryTokenSet(address indexed token, bool isDeflationary);
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
        require(token != address(0), ErrorCodes.E001);
        allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token);
    }
    function removeAllowedToken(address token) external onlyOperatorWithTimelock {
        require(token != address(0), ErrorCodes.E001);
        allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token);
    }

    function setDeflationaryToken(address token, bool _isDeflationary) external onlyOperatorWithTimelock {
        require(token != address(0), ErrorCodes.E001);
        isDeflationaryToken[token] = _isDeflationary;
        emit DeflationaryTokenSet(token, _isDeflationary);
    }
    function _safeTokenTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 actualReceived) {
        if (isDeflationaryToken[address(token)]) {
            uint256 balanceBefore = token.balanceOf(to);
            require(token.transferFrom(from, to, amount), ErrorCodes.E901);
            uint256 balanceAfter = token.balanceOf(to);

            actualReceived = balanceAfter - balanceBefore;
            if (actualReceived != amount) {
            }
        } else {
            require(token.transferFrom(from, to, amount), ErrorCodes.E901);
            actualReceived = amount;
        }
    }
    function _safeTokenTransfer(
        IERC20 token,
        address to,
        uint256 amount
    ) internal returns (uint256 actualSent) {
        if (isDeflationaryToken[address(token)]) {
            uint256 balanceBefore = token.balanceOf(address(this));
            require(token.transfer(to, amount), ErrorCodes.E901);
            uint256 balanceAfter = token.balanceOf(address(this));

            actualSent = balanceBefore - balanceAfter;
            if (actualSent != amount) {
            }
        } else {
            require(token.transfer(to, amount), ErrorCodes.E901);
            actualSent = amount;
        }
    }
    function setWhitelistEnabled(bool enabled) external onlyOperatorWithTimelock {
        whitelistEnabled = enabled;
        emit WhitelistStatusChanged(enabled);
    }
    function setTimelock(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(t != address(0), ErrorCodes.E603);
        require(address(timelock) == address(0), ErrorCodes.E601);
        timelock = PropertyMarketTimelock(payable(t));
        emit TimelockSet(t);
    }
    function setMultiSigOperator(address m) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(m != address(0), ErrorCodes.E604);
        require(address(multiSigOperator) == address(0), ErrorCodes.E602);
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
    function purchaseProperty(uint256 tokenId, uint256 offerPrice) external payable nonReentrant onlyKYCVerified onlyValidAmount(offerPrice) {
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
        if (paymentToken == address(0)) {
            require(msg.value >= actualPrice, ErrorCodes.E601);
        } else {
            IERC20 token = IERC20(paymentToken);
            uint256 actualReceived = _safeTokenTransferFrom(token, msg.sender, address(this), actualPrice);
            if (isDeflationaryToken[paymentToken] && actualReceived < actualPrice) {
                actualPrice = actualReceived;
            }
        }
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

        if (purchase.paymentToken == address(0)) {
            (bool success, ) = payable(purchase.buyer).call{value: purchase.offerPrice}("");
            require(success, ErrorCodes.E902);
        } else {
            IERC20 token = IERC20(purchase.paymentToken);
            _safeTokenTransfer(token, purchase.buyer, purchase.offerPrice);
        }
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
        if (paymentToken == address(0)) {
            (bool success, ) = payable(bidder).call{value: amount, gas: 10000}("");
            if (!success) {
                pendingRefunds[bidder] += amount;

                emit RefundQueued(bidder, amount);
            }
        } else {
            try IERC20(paymentToken).transfer(bidder, amount) returns (bool success) {
                if (!success) {
                    pendingTokenRefunds[bidder][paymentToken] += amount;

                }
            } catch {
                pendingTokenRefunds[bidder][paymentToken] += amount;

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
        uint256 minimumPrice = highestBid > 0 ? highestBid : listedPrice;

        if (paymentToken == address(0)) {
            return msg.value >= minimumPrice && offerPrice >= minimumPrice && msg.value == offerPrice;
        } else {
            return offerPrice >= minimumPrice;
        }
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
        uint256 fees = (amount * feeConfig.baseFee) / PERCENTAGE_BASE;
        uint256 netValue = amount - fees;

        if (paymentToken == address(0)) {
            (bool successSeller, ) = payable(seller).call{value: netValue}("");
            require(successSeller, ErrorCodes.E903);
            (bool successFee, ) = payable(feeConfig.feeCollector).call{value: fees}("");
            require(successFee, ErrorCodes.E904);
        } else {
            IERC20 token = IERC20(paymentToken);
            _safeTokenTransfer(token, seller, netValue);
            _safeTokenTransfer(token, feeConfig.feeCollector, fees);
        }
    }
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
    modifier onlyOperator() {
        require(hasRole(OPERATOR_ROLE, msg.sender), ErrorCodes.E402);
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        require(nftiContract.ownerOf(tokenId) == msg.sender, ErrorCodes.E002);
        _;
    }
    modifier onlyOperatorWithTimelock() {
        if (timelockEnabled && address(timelock) != address(0)) {
            require(msg.sender == address(timelock), ErrorCodes.E601);
        } else {
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

    function placeBid(uint256 tokenId, uint256 bidAmount, address paymentToken) external payable nonReentrant onlyKYCVerified onlyAllowedToken(paymentToken) onlyValidAmount(bidAmount) {
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
            require(bidAmount >= oldAmount, ErrorCodes.E205);

            if (bidAmount > oldAmount) {
                uint256 additionalAmount = bidAmount - oldAmount;
                if (paymentToken == address(0)) {
                    require(msg.value == additionalAmount, ErrorCodes.E706);
                } else {
                    IERC20 token = IERC20(paymentToken);
                    require(token.allowance(msg.sender, address(this)) >= additionalAmount, ErrorCodes.E208);
                    uint256 actualReceived = _safeTokenTransferFrom(token, msg.sender, address(this), additionalAmount);
                    if (isDeflationaryToken[paymentToken] && actualReceived < additionalAmount) {
                        bidAmount = existingBid.amount + actualReceived;
                    }
                }
            } else {
                require(msg.value == 0, ErrorCodes.E608);
            }
        } else {
            if (paymentToken == address(0)) {
                require(msg.value == bidAmount, ErrorCodes.E207);
            } else {
                IERC20 token = IERC20(paymentToken);
                require(token.allowance(msg.sender, address(this)) >= bidAmount, ErrorCodes.E208);
                uint256 actualReceived = _safeTokenTransferFrom(token, msg.sender, address(this), bidAmount);
                if (isDeflationaryToken[paymentToken] && actualReceived < bidAmount) {
                    bidAmount = actualReceived;
                }
            }
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

        if (bid.paymentToken == address(0)) {
            listing.status = PropertyStatus.PENDING_PAYMENT;
            uint32 deadline = uint32(block.timestamp + PAYMENT_TIMEOUT);
            paymentDeadlines[tokenId] = deadline;

            emit BidAcceptedPendingPayment(tokenId, listing.seller, bid.bidder, bid.amount, bid.paymentToken);
        } else {
            listing.status = PropertyStatus.SOLD;
            bid.isActive = false;
            bidIndexByBidder[bid.bidder][tokenId] = 0;
            _processPaymentFromBalance(listing.seller, bid.amount, bid.paymentToken);
            nftiContract.safeTransferFrom(listing.seller, bid.bidder, tokenId, "");
            emit BidAccepted(tokenId, listing.seller, bid.bidder, bid.amount, bid.paymentToken);
        }
        _cancelOtherBids(tokenId, bid.bidder);
    }

    function completeBidPayment(uint256 tokenId) external payable nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.PENDING_PAYMENT, ErrorCodes.E504);
        require(block.timestamp <= paymentDeadlines[tokenId], ErrorCodes.E906);
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        require(bidIndex > 0, ErrorCodes.E907);

        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, ErrorCodes.E908);
        require(bid.bidder == msg.sender, ErrorCodes.E909);
        require(bid.paymentToken == address(0), ErrorCodes.E910);
        require(msg.value == 0, ErrorCodes.E608);
        listing.status = PropertyStatus.SOLD;
        bid.isActive = false;
        bidIndexByBidder[msg.sender][tokenId] = 0;
        delete paymentDeadlines[tokenId];
        uint256 fees = (bid.amount * feeConfig.baseFee) / PERCENTAGE_BASE;
        uint256 netValue = bid.amount - fees;
        (bool successSeller, ) = payable(listing.seller).call{value: netValue}("");
        require(successSeller, ErrorCodes.E609);
        (bool successFee, ) = payable(feeConfig.feeCollector).call{value: fees}("");
        require(successFee, ErrorCodes.E610);
        nftiContract.safeTransferFrom(listing.seller, msg.sender, tokenId, "");

        emit BidAccepted(tokenId, listing.seller, msg.sender, bid.amount, bid.paymentToken);
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
        if (paymentToken == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
            require(success, ErrorCodes.E303);
        } else {
            IERC20 token = IERC20(paymentToken);
            _safeTokenTransfer(token, msg.sender, refundAmount);
        }

        emit BidCancelled(tokenId, msg.sender, refundAmount);
    }

    function withdrawPendingRefund() external nonReentrant {
        uint256 refundAmount = pendingRefunds[msg.sender];
        require(refundAmount > 0, ErrorCodes.E704);

        pendingRefunds[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        require(success, ErrorCodes.E705);

        emit RefundWithdrawn(msg.sender, refundAmount);
    }

    function cancelExpiredPayment(uint256 tokenId) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.PENDING_PAYMENT, ErrorCodes.E702);
        require(block.timestamp > paymentDeadlines[tokenId], ErrorCodes.E703);
        uint256 bidIndex = 0;
        address bidder = address(0);
        uint256 bidAmount = 0;

        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive && bids[i].paymentToken == address(0)) {
                bidIndex = i;
                bidder = bids[i].bidder;
                bidAmount = bids[i].amount;
                break;
            }
        }

        require(bidder != address(0), ErrorCodes.E701);
        bids[bidIndex].isActive = false;
        bidIndexByBidder[bidder][tokenId] = 0;
        listing.status = PropertyStatus.LISTED;
        delete paymentDeadlines[tokenId];
        _refundBid(bidder, bidAmount, address(0), tokenId);

        emit PaymentExpired(tokenId, bidder, bidAmount);
    }


    function emergencyWithdrawETH(uint256 amount, address payable recipient) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), ErrorCodes.E912);
        require(recipient != address(0), ErrorCodes.E913);
        require(amount <= address(this).balance, ErrorCodes.E914);

        (bool success, ) = recipient.call{value: amount}("");
        require(success, ErrorCodes.E905);

        emit EmergencyWithdrawal(recipient, amount);
    }

    function emergencyWithdrawToken(address token, uint256 amount, address recipient) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), ErrorCodes.E912);
        require(token != address(0), ErrorCodes.E915);
        require(recipient != address(0), ErrorCodes.E913);

        IERC20 tokenContract = IERC20(token);
        require(amount <= tokenContract.balanceOf(address(this)), ErrorCodes.E916);

        bool success = tokenContract.transfer(recipient, amount);
        require(success, ErrorCodes.E901);

        emit EmergencyTokenWithdrawal(token, recipient, amount);
    }

}
