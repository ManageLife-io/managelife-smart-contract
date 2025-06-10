// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../governance/AdminControl.sol";

/// @title PropertyMarket - A decentralized marketplace for real estate NFTs
/// @notice This contract enables listing, buying, selling and bidding on real estate NFTs
/// @dev Implements a secure marketplace with protection against frontrunning
contract PropertyMarket is ReentrancyGuard, Pausable, AccessControl, AdminControl {
    using ECDSA for bytes32;

    // ========== Constants ==========
    uint256 public constant PERCENTAGE_BASE = 10000; // Base for percentage calculations (100% = 10000)
    uint256 public constant MIN_BID_INCREMENT_PERCENT = 5;
    uint256 public constant BID_TIMEOUT = 24 hours; // Time window for bid finalization
    uint256 public constant COMMITMENT_EXPIRY = 1 hours; // Time window for bid commitment reveal
    
    // ========== Data Structures ==========
    enum PropertyStatus { LISTED, RENTED, SOLD, DELISTED }    
    
    struct Bid {
        uint256 tokenId;
        address bidder;
        uint256 amount;
        address paymentToken;
        uint256 bidTimestamp;
        bool isActive;
        bytes32 commitment; // Hash commitment of the bid
        uint256 commitmentTimestamp;
        bool isRevealed;
        bytes signature; // Signed bid data
    }
    
    struct PropertyListing {
        uint256 tokenId;
        address seller;
        uint256 price;
        address paymentToken;
        PropertyStatus status;
        uint256 listTimestamp;
        uint256 lastRenewed;
        uint256 highestBidAmount;
        address highestBidder;
        uint256 bidEndTime;
        uint256 minBidIncrement;
    }

    // ========== State Variables ==========
    IERC721 public immutable nftiContract;
    IERC721 public immutable nftmContract;
    
    // Token whitelist for payments
    mapping(address => bool) public allowedPaymentTokens;
    bool public whitelistEnabled = true;
    
    mapping(uint256 => PropertyListing) public listings;
    mapping(address => mapping(uint256 => uint256)) public leaseTerms;
    
    // Bidding related mappings
    mapping(uint256 => Bid[]) public bidsForToken;
    mapping(uint256 => mapping(address => uint256)) public ethBidDeposits;
    mapping(address => mapping(uint256 => uint256)) public bidIndexByBidder;
    mapping(bytes32 => bool) public usedCommitments; // Track used bid commitments
    mapping(bytes32 => bool) public usedSignatures; // Track used bid signatures

    // ========== Events ==========
    event NewListing(uint256 indexed tokenId, address indexed seller, uint256 price, address paymentToken);
    event PropertySold(uint256 indexed tokenId, address buyer, uint256 price, address paymentToken);
    event ListingUpdated(uint256 indexed tokenId, uint256 newPrice, address newPaymentToken);
    event BidCommitmentPlaced(uint256 indexed tokenId, address indexed bidder, bytes32 commitment);
    event BidRevealed(uint256 indexed tokenId, address indexed bidder, uint256 amount, address paymentToken);
    event BidAccepted(uint256 indexed tokenId, address indexed seller, address indexed bidder, uint256 amount, address paymentToken);
    event BidCancelled(uint256 indexed tokenId, address indexed bidder, uint256 amount);
    event PaymentTokenAdded(address indexed token, address indexed operator);
    event PaymentTokenRemoved(address indexed token, address indexed operator);
    event WhitelistStatusChanged(bool enabled, address indexed operator);

    constructor(
        address _nftiAddress,
        address _nftmAddress,
        address initialAdmin,
        address feeCollector,
        address rewardsVault
    ) AdminControl(initialAdmin, feeCollector, rewardsVault) {
        require(_nftiAddress != address(0), "Invalid NFTi address");
        require(_nftmAddress != address(0), "Invalid NFTm address");
        allowedPaymentTokens[address(0)] = true; // ETH as default payment
        nftiContract = IERC721(_nftiAddress);
        nftmContract = IERC721(_nftmAddress);
    }

    // ========== Bidding Functions ==========
    
    /// @notice Creates a commitment for a bid without revealing the actual amount
    /// @dev Uses a hash commitment scheme to prevent frontrunning
    /// @param tokenId The NFT token ID
    /// @param commitment The hash of (amount + nonce + bidder + tokenId)
    function commitBid(uint256 tokenId, bytes32 commitment) external nonReentrant {
        require(!usedCommitments[commitment], "Commitment already used");
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Property not listed");
        require(listing.seller != msg.sender, "Cannot bid on own listing");
        require(this.isKYCVerified(msg.sender), "KYC required");
        
        // Store the commitment
        Bid memory newBid = Bid({
            tokenId: tokenId,
            bidder: msg.sender,
            amount: 0, // Amount is revealed later
            paymentToken: address(0), // Set during reveal
            bidTimestamp: block.timestamp,
            isActive: true,
            commitment: commitment,
            commitmentTimestamp: block.timestamp,
            isRevealed: false,
            signature: new bytes(0)
        });
        
        bidsForToken[tokenId].push(newBid);
        bidIndexByBidder[msg.sender][tokenId] = bidsForToken[tokenId].length;
        usedCommitments[commitment] = true;
        
        emit BidCommitmentPlaced(tokenId, msg.sender, commitment);
    }

    /// @notice Reveals a previously committed bid
    /// @dev Verifies the commitment and signature to prevent frontrunning
    /// @param tokenId The NFT token ID
    /// @param amount The bid amount
    /// @param paymentToken The token to be used for payment
    /// @param nonce Random value used in the commitment
    /// @param signature Signed bid data
    function revealBid(
        uint256 tokenId,
        uint256 amount,
        address paymentToken,
        bytes32 nonce,
        bytes calldata signature
    ) external payable nonReentrant {
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId] - 1;
        require(bidIndex < bidsForToken[tokenId].length, "Bid not found");
        
        Bid storage bid = bidsForToken[tokenId][bidIndex];
        require(bid.isActive && !bid.isRevealed, "Invalid bid state");
        require(block.timestamp <= bid.commitmentTimestamp + COMMITMENT_EXPIRY, "Commitment expired");
        
        // Verify commitment
        bytes32 commitment = keccak256(abi.encodePacked(amount, paymentToken, nonce, msg.sender, tokenId));
        require(commitment == bid.commitment, "Invalid commitment");
        
        // Verify signature hasn't been used
        bytes32 signatureHash = keccak256(signature);
        require(!usedSignatures[signatureHash], "Signature already used");
        
        // Verify signature
        bytes32 bidHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            keccak256(abi.encodePacked(tokenId, amount, paymentToken, nonce))
        ));
        address signer = bidHash.recover(signature);
        require(signer == msg.sender, "Invalid signature");
        
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Property not listed");
        require(amount >= listing.price, "Bid below listing price");
        
        // Check minimum bid increment
        if (listing.highestBidAmount > 0) {
            uint256 minBid = listing.highestBidAmount + 
                ((listing.highestBidAmount * listing.minBidIncrement) / PERCENTAGE_BASE);
            require(amount >= minBid, "Bid increment too low");
        }
        
        // Validate payment
        if (paymentToken == address(0)) {
            require(msg.value == amount, "Incorrect ETH amount");
            ethBidDeposits[tokenId][msg.sender] = amount;
        } else {
            require(isTokenAllowed(paymentToken), "Payment token not allowed");
            IERC20 token = IERC20(paymentToken);
            require(token.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        }
        
        // Update bid
        bid.amount = amount;
        bid.paymentToken = paymentToken;
        bid.isRevealed = true;
        bid.signature = signature;
        usedSignatures[signatureHash] = true;
        
        // Update listing if highest bid
        if (amount > listing.highestBidAmount) {
            listing.highestBidAmount = amount;
            listing.highestBidder = msg.sender;
            listing.bidEndTime = block.timestamp + BID_TIMEOUT;
        }
        
        emit BidRevealed(tokenId, msg.sender, amount, paymentToken);
    }

    /// @notice Accepts the highest bid for a property
    /// @dev Can only be called by the seller after bid timeout
    /// @param tokenId The NFT token ID
    function acceptHighestBid(uint256 tokenId) external nonReentrant {
        PropertyListing storage listing = listings[tokenId];
        require(listing.status == PropertyStatus.LISTED, "Not listed");
        require(listing.seller == msg.sender, "Not seller");
        require(listing.highestBidder != address(0), "No valid bids");
        require(block.timestamp >= listing.bidEndTime, "Bid timeout not reached");
        
        address winner = listing.highestBidder;
        uint256 winningAmount = listing.highestBidAmount;
        address paymentToken = bidsForToken[tokenId][bidIndexByBidder[winner][tokenId] - 1].paymentToken;
        
        // Update state
        listing.status = PropertyStatus.SOLD;
        
        // Process payment
        _processPayment(listing.seller, winningAmount, paymentToken);
        
        // Transfer NFT
        nftiContract.safeTransferFrom(listing.seller, winner, tokenId);
        
        // Clear other bids
        _clearAllBidsExcept(tokenId, bidIndexByBidder[winner][tokenId] - 1);
        
        emit PropertySold(tokenId, winner, winningAmount, paymentToken);
    }

    /// @notice Cancels an active bid
    /// @dev Only the original bidder can cancel their bid
    /// @param tokenId The NFT token ID
    function cancelBid(uint256 tokenId) external nonReentrant {
        uint256 bidIndex = bidIndexByBidder[msg.sender][tokenId];
        require(bidIndex > 0, "No active bid");
        
        Bid storage bid = bidsForToken[tokenId][bidIndex - 1];
        require(bid.isActive, "Bid not active");
        require(bid.bidder == msg.sender, "Not bidder");
        
        // If this was the highest bid, remove it from listing
        PropertyListing storage listing = listings[tokenId];
        if (listing.highestBidder == msg.sender) {
            listing.highestBidder = address(0);
            listing.highestBidAmount = 0;
            listing.bidEndTime = 0;
        }
        
        bid.isActive = false;
        bidIndexByBidder[msg.sender][tokenId] = 0;
        
        // Refund ETH if applicable
        if (bid.paymentToken == address(0) && bid.isRevealed) {
            uint256 ethAmount = ethBidDeposits[tokenId][msg.sender];
            ethBidDeposits[tokenId][msg.sender] = 0;
            (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
            require(success, "ETH refund failed");
        }
        
        emit BidCancelled(tokenId, msg.sender, bid.amount);
    }

    // ========== Internal Functions ==========
    function _clearAllBidsExcept(uint256 tokenId, uint256 winningBidIndex) internal {
        Bid[] storage bids = bidsForToken[tokenId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (i != winningBidIndex && bids[i].isActive) {
                bids[i].isActive = false;
                if (bids[i].paymentToken == address(0) && bids[i].isRevealed) {
                    address bidder = bids[i].bidder;
                    uint256 ethAmount = ethBidDeposits[tokenId][bidder];
                    if (ethAmount > 0) {
                        ethBidDeposits[tokenId][bidder] = 0;
                        (bool success, ) = payable(bidder).call{value: ethAmount}("");
                        require(success, "ETH refund failed");
                    }
                }
                emit BidCancelled(tokenId, bids[i].bidder, bids[i].amount);
            }
        }
    }

    function _processPayment(
        address seller,
        uint256 amount,
        address paymentToken
    ) internal {
        uint256 baseFee = feeConfig.baseFee;
        address feeCollector = feeConfig.feeCollector;
        uint256 fees = (amount * baseFee) / PERCENTAGE_BASE;
        uint256 netAmount = amount - fees;
        
        if (paymentToken == address(0)) {
            // Process ETH payment
            (bool successSeller, ) = payable(seller).call{value: netAmount}("");
            require(successSeller, "Seller payment failed");
            (bool successFee, ) = payable(feeCollector).call{value: fees}("");
            require(successFee, "Fee payment failed");
        } else {
            // Process ERC20 payment
            IERC20 token = IERC20(paymentToken);
            require(token.transferFrom(msg.sender, seller, netAmount), "Seller payment failed");
            require(token.transferFrom(msg.sender, feeCollector, fees), "Fee payment failed");
        }
    }

    // ... Rest of the contract (listing, payment token management, etc.) remains the same
} 