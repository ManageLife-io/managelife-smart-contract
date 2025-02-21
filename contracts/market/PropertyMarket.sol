// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../nft/NFTi.sol";
import "../governance/AdminControl.sol";

contract PropertyMarket is ReentrancyGuard {
    using SafeMath for uint256;

    // ========== 交易类型定义 ========== 
    enum ListingType { ForSale, ForRent }
    enum PaymentCurrency { LIFE, ETH, USDT }

    // ========== 房产挂牌结构体 ==========
    struct PropertyListing {
        address seller;
        uint256 price;
        ListingType listingType;
        PaymentCurrency currency;
        bool isActive;
        uint256 LLCId; // 法律实体ID
    }

    // ========== 状态变量 ==========
    NFTi public immutable nftiContract;  // 资产NFT合约
    AdminControl public adminControl;    // 管理控制合约
    IERC20 public immutable lifeToken;   // LIFE代币
    IERC20 public immutable usdtToken;   // USDT稳定币

    mapping(uint256 => PropertyListing) public listings;      // NFTID => 挂牌信息
    mapping(address => bool) public verifiedWallets;          // KYC认证名单

    // ========== 事件定义 ==========
    event PropertyListed(
        uint256 indexed tokenId,
        uint256 price,
        ListingType lType,
        PaymentCurrency currency
    );
    event PropertySold(
        uint256 indexed tokenId,
        address buyer,
        address seller,
        uint256 finalPrice
    );
    event KycVerified(address indexed wallet, bool status);

    // ========== 构造函数 ==========
    constructor(
        address _nfti,
        address _admin,
        address _lifeToken,
        address _usdtToken
    ) {
        nftiContract = NFTi(_nfti);
        adminControl = AdminControl(_admin);
        lifeToken = IERC20(_lifeToken);
        usdtToken = IERC20(_usdtToken);
    }

    // ========== 核心交易函数 ==========

    /**
     * @dev 挂牌房产（需持有NFTi并通过KYC）
     */
    function listProperty(
        uint256 tokenId,
        uint256 price,
        ListingType lType,
        PaymentCurrency currency,
        uint256 LLCId
    ) external {
        require(nftiContract.ownerOf(tokenId) == msg.sender, "Not NFT owner");
        require(verifiedWallets[msg.sender], "KYC verification required");

        listings[tokenId] = PropertyListing({
            seller: msg.sender,
            price: price,
            listingType: lType,
            currency: currency,
            isActive: true,
            LLCId: LLCId
        });

        emit PropertyListed(tokenId, price, lType, currency);
    }

    /**
     * @dev 使用ETH购买房产
     */
    function buyWithETH(uint256 tokenId)
        external
        payable
        nonReentrant
        onlyVerified
    {
        PropertyListing memory listing = listings[tokenId];
        require(listing.isActive, "Listing not active");
        require(listing.currency == PaymentCurrency.ETH, "Currency mismatch");

        (uint256 tradeFee, ) = adminControl.getFeeConfig();
        uint256 requiredValue = listing.price.add(
            listing.price.mul(tradeFee).div(10000)
        );
        
        require(msg.value >= requiredValue, "Insufficient payment");

        // 分发资金
        uint256 sellerAmount = listing.price;
        uint256 feeAmount = requiredValue.sub(sellerAmount);
        
        payable(listing.seller).transfer(sellerAmount);
        payable(address(adminControl)).transfer(feeAmount);

        // 转移NFT
        _transferNFT(listing.seller, msg.sender, tokenId);
        
        emit PropertySold(tokenId, msg.sender, listing.seller, listing.price);
    }

    /**
     * @dev 使用ERC20代币购买房产
     */
    function buyWithERC20(uint256 tokenId) external nonReentrant onlyVerified {
        PropertyListing memory listing = listings[tokenId];
        require(listing.isActive, "Listing not active");
        require(listing.currency != PaymentCurrency.ETH, "Use ETH method");

        IERC20 token = (listing.currency == PaymentCurrency.LIFE) 
            ? lifeToken 
            : usdtToken;

        (uint256 tradeFee, ) = adminControl.getFeeConfig();
        uint256 totalAmount = listing.price.add(
            listing.price.mul(tradeFee).div(10000)
        );

        // 转账代币
        require(
            token.transferFrom(msg.sender, address(this), totalAmount),
            "Payment failed"
        );
        
        // 分配资金：给卖家的金额+手续费
        token.transfer(listing.seller, listing.price);
        token.transfer(address(adminControl), totalAmount.sub(listing.price));

        // 转移NFT
        _transferNFT(listing.seller, msg.sender, tokenId);
        
        emit PropertySold(tokenId, msg.sender, listing.seller, listing.price);
    }

    // ========== 管理功能 ==========

    /**
     * @dev 设置KYC认证状态（仅管理员）
     */
    function setKycStatus(address[] calldata wallets, bool status) external onlyAdmin {
        for (uint256 i = 0; i < wallets.length; i++) {
            verifiedWallets[wallets[i]] = status;
            emit KycVerified(wallets[i], status);
        }
    }

    // ========== 内部函数 ==========
    
    /**
     * @dev 安全转移NFT
     */
    function _transferNFT(address from, address to, uint256 tokenId) internal {
        nftiContract.safeTransferFrom(from, to, tokenId);
        delete listings[tokenId]; // 下架房产
    }

    // ========== 修饰符 ==========
    
    modifier onlyAdmin() {
        require(
            msg.sender == adminControl.owner() ||
            msg.sender == adminControl.operator(),
            "Admin access required"
        );
        _;
    }

    modifier onlyVerified() {
        require(verifiedWallets[msg.sender], "KYC verification required");
        _;
    }
}
