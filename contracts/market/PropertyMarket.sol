// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../governance/AdminControl.sol";

contract PropertyMarket is ReentrancyGuard {
    // ========== 数据结构 ==========
    enum PropertyStatus { LISTED, RENTED, SOLD, DELISTED }    
    
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
    }

    // ========== 状态变量 ==========
    AdminControl public immutable adminControl;
    IERC721 public immutable nftiContract;
    IERC721 public immutable nftmContract;
    
    mapping(uint256 => PropertyListing) public listings;
    mapping(address => mapping(uint256 => uint256)) public leaseTerms;
    
    // 竞价相关映射
    mapping(uint256 => Bid[]) public bidsForToken; // tokenId => 所有出价
    mapping(address => mapping(uint256 => uint256)) public bidIndexByBidder; // bidder => tokenId => bidIndex+1 (0表示无出价)

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
    
    // 竞价相关事件
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
    
    // ========== 竞价功能 ==========
    
    /**
     * @dev 买家对NFT进行出价
     * @param tokenId NFT的ID
     * @param bidAmount 出价金额
     * @param paymentToken 支付代币地址（0地址表示ETH）
     */
    function placeBid(uint256 tokenId, uint256 bidAmount, address paymentToken) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Property not listed");
        require(listing.seller != msg.sender, "Cannot bid on your own listing");
        require(bidAmount > 0, "Bid amount must be greater than 0");
        require(adminControl.isKYCVerified(msg.sender), "KYC required");
        
        // 检查是否已有出价，如果有则更新
        uint256 existingBidIndex = bidIndexByBidder[msg.sender][tokenId];
        
        // 处理代币授权
        if (paymentToken != address(0)) {
            IERC20 token = IERC20(paymentToken);
            // 检查授权额度
            uint256 allowance = token.allowance(msg.sender, address(this));
            require(allowance >= bidAmount, "Insufficient token allowance");
        }
        
        if (existingBidIndex > 0) {
            // 更新现有出价
            Bid storage existingBid = bidsForToken[tokenId][existingBidIndex - 1];
            require(existingBid.isActive, "Bid is not active");
            existingBid.amount = bidAmount;
            existingBid.paymentToken = paymentToken;
            existingBid.bidTimestamp = block.timestamp;
        } else {
            // 创建新出价
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
    
    /**
     * @dev 卖家接受特定买家的出价
     * @param tokenId NFT的ID
     * @param bidder 买家地址
     */
    function acceptBid(uint256 tokenId, address bidder) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Property not listed");
        require(listing.seller == msg.sender, "Not the seller");
        
        uint256 bidIndex = bidIndexByBidder[bidder][tokenId];
        require(bidIndex > 0, "No bid from this bidder");
        
        Bid storage acceptedBid = bidsForToken[tokenId][bidIndex - 1];
        require(acceptedBid.isActive, "Bid is not active");
        
        // 确保NFT所有权
        require(nftiContract.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        
        // 处理支付
        (uint256 baseFee,, address feeCollector) = adminControl.feeConfig();
        uint256 fees = (acceptedBid.amount * baseFee) / 10000;
        uint256 netValue = acceptedBid.amount - fees;
        
        if (acceptedBid.paymentToken == address(0)) {
            // ETH支付 - 这种情况下需要买家发送ETH
            // 由于我们使用预授权模式，这里不处理ETH转账
            revert("ETH bids not supported in this version");
        } else {
            // ERC20代币支付
            IERC20 token = IERC20(acceptedBid.paymentToken);
            
            // 从买家转账到卖家
            require(
                token.transferFrom(acceptedBid.bidder, msg.sender, netValue),
                "Transfer to seller failed"
            );
            
            // 从买家转账到费用收集者
            require(
                token.transferFrom(acceptedBid.bidder, feeCollector, fees),
                "Fee transfer failed"
            );
        }
        
        // 转移NFT
        nftiContract.transferFrom(msg.sender, acceptedBid.bidder, tokenId);
        
        // 更新状态
        listing.status = PropertyStatus.SOLD;
        acceptedBid.isActive = false;
        
        // 清除该NFT的所有其他出价
        _clearAllBidsExcept(tokenId, bidIndex - 1);
        
        emit BidAccepted(
            tokenId,
            msg.sender,
            acceptedBid.bidder,
            acceptedBid.amount,
            acceptedBid.paymentToken
        );
    }
    
    /**
     * @dev 买家取消自己的出价
     * @param tokenId NFT的ID
     */
    function cancelBid(uint256 tokenId) external nonReentrant {
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        require(bidIndex > 0, "No active bid");
        
        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, "Bid already inactive");
        require(bid.bidder == msg.sender, "Not the bidder");
        
        bid.isActive = false;
        bidIndexByBidder[msg.sender][tokenId] = 0;
        
        emit BidCancelled(tokenId, msg.sender, bid.amount);
    }
    
    /**
     * @dev 获取特定NFT的所有活跃出价
     * @param tokenId NFT的ID
     * @return 活跃出价数组
     */
    function getActiveBidsForToken(uint256 tokenId) external view returns (Bid[] memory) {
        Bid[] storage allBids = bidsForToken[tokenId];
        uint256 activeCount = 0;
        
        // 计算活跃出价数量
        for (uint256 i = 0; i < allBids.length; i++) {
            if (allBids[i].isActive) {
                activeCount++;
            }
        }
        
        // 创建结果数组
        Bid[] memory activeBids = new Bid[](activeCount);
        uint256 currentIndex = 0;
        
        // 填充结果数组
        for (uint256 i = 0; i < allBids.length; i++) {
            if (allBids[i].isActive) {
                activeBids[currentIndex] = allBids[i];
                currentIndex++;
            }
        }
        
        return activeBids;
    }
    
    /**
     * @dev 获取特定买家对特定NFT的出价
     * @param tokenId NFT的ID
     * @param bidder 买家地址
     * @return 出价信息，如果不存在则返回默认值
     */
    function getBidFromBidder(uint256 tokenId, address bidder) external view returns (Bid memory) {
        uint256 bidIndex = bidIndexByBidder[bidder][tokenId];
        if (bidIndex == 0) {
            // 返回空出价
            return Bid(0, address(0), 0, address(0), 0, false);
        }
        
        return bidsForToken[tokenId][bidIndex - 1];
    }
    
    /**
     * @dev 清除NFT的所有出价，除了指定的一个
     * @param tokenId NFT的ID
     * @param exceptIndex 不清除的出价索引
     */
    function _clearAllBidsExcept(uint256 tokenId, uint256 exceptIndex) private {
        Bid[] storage bids = bidsForToken[tokenId];
        
        for (uint256 i = 0; i < bids.length; i++) {
            if (i != exceptIndex && bids[i].isActive) {
                bids[i].isActive = false;
                bidIndexByBidder[bids[i].bidder][tokenId] = 0;
            }
        }
    }
}
