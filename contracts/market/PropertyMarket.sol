// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../governance/AdminControl.sol";

contract PropertyMarket is ReentrancyGuard {
    // ========== 数据结构 ==========
    enum PropertyStatus { LISTED, RENTED, SOLD, DELISTED }
    
    struct PropertyListing {
        uint256 tokenId;
        address seller;
        uint256 price;
        address paymentToken;
        PropertyStatus status;
        uint256 listTimestamp;
        uint256 lastRenewed;
    }

    // ========== 状态变量 ==========
    AdminControl public immutable adminControl;
    IERC721 public immutable nftiContract;
    IERC721 public immutable nftmContract;
    
    mapping(uint256 => PropertyListing) public listings;
    mapping(address => mapping(uint256 => uint256)) public leaseTerms;

    // ========== 事件定义 ==========
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

    // ========== 构造函数 ==========
    constructor(
        address _adminControl,
        address _nftiAddress,
        address _nftmAddress
    ) {
        adminControl = AdminControl(_adminControl);
        nftiContract = IERC721(_nftiAddress);
        nftmContract = IERC721(_nftmAddress);
    }

    // ========== 核心功能 ==========
    function listProperty(
        uint256 tokenId,
        uint256 price,
        address paymentToken
    ) external nonReentrant {
        require(
            nftiContract.ownerOf(tokenId) == msg.sender,
            "Not NFTi owner"
        );
        
        require(
            adminControl.isKYCVerified(msg.sender),
            "KYC required"
        );
        
        require(price > 0, "Invalid price");

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

    function purchaseProperty(
        uint256 tokenId,
        uint256 offerPrice
    ) external payable nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        
        require(
            listing.status == PropertyStatus.LISTED,
            "Not available"
        );
        
        require(
            adminControl.isKYCVerified(msg.sender),
            "KYC required"
        );
        
        require(
            _validatePayment(listing.price, offerPrice, listing.paymentToken),
            "Payment failed"
        );

        _processPayment(
            listing.seller,
            listing.price,
            listing.paymentToken
        );

        nftiContract.transferFrom(
            listing.seller,
            msg.sender,
            tokenId
        );
        listing.status = PropertyStatus.SOLD;
        
        emit PropertySold(
            tokenId,
            msg.sender,
            listing.price,
            listing.paymentToken
        );
    }

    // ========== 支付处理函数 ==========
    function _validatePayment(
        uint256 listedPrice,
        uint256 offerPrice,
        address paymentToken
    ) private view returns (bool) {
        if (paymentToken == address(0)) {
            return msg.value >= listedPrice && offerPrice == listedPrice;
        } else {
            return offerPrice == listedPrice;
        }
    }

    function _processPayment(
        address seller,
        uint256 price,
        address paymentToken
    ) internal {
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig();
        uint256 fees = (price * baseFee) / 10000;
        uint256 netValue = price - fees;

        if (paymentToken == address(0)) {
            require(msg.value >= price, "Insufficient ETH");
            
            if (msg.value > price) {
                payable(msg.sender).transfer(msg.value - price);
            }
            
            payable(seller).transfer(netValue);
            payable(feeCollector).transfer(fees);
        } else {
            IERC20 token = IERC20(paymentToken);
            require(
                token.transferFrom(msg.sender, seller, netValue),
                "Transfer failed"
            );
            require(
                token.transferFrom(msg.sender, feeCollector, fees),
                "Fee transfer failed"
            );
        }
    }

    // ========== 管理功能 ==========
    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken
    ) external onlyOperator {
        PropertyListing storage listing = listings[tokenId];
        require(
            listing.status == PropertyStatus.LISTED,
            "Not active listing"
        );

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.lastRenewed = block.timestamp;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken);
    }

    // ========== 权限修饰符 ==========
    modifier onlyOperator() {
        bytes32 role = adminControl.OPERATOR_ROLE();
        require(
            adminControl.hasRole(role, msg.sender),
            "Operator required"
        );
        _;
    }

    // ========== 辅助功能 ==========
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
}
