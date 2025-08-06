// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title PropertyAuction
 * @notice On-chain English auction for high-ticket real-estate NFTs.
 *         – bids are on-chain but non-custodial (no funds pulled)
 *         – when auction ends, seller escrows the NFT, winner escrows funds
 *         – contract settles atomically (DvP) once both legs are present
 *         – if either side defaults past ESCROW_PERIOD, the other party can void
 */
contract PropertyAuction is
    ReentrancyGuard,
    Pausable,
    Ownable,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    /* -------------------------------------------------------------------------- */
    /*                                    ERRORS                                  */
    /* -------------------------------------------------------------------------- */

    error InvalidParams();
    error AuctionNotFound();
    error AuctionActive();
    error AuctionNotActive();
    error AuctionExpired();
    error NotSeller();
    error NotWinner();
    error BidTooLow(uint256 required);
    error NFTAlreadyDeposited();
    error FundsAlreadyDeposited();
    error NotSettleable();
    error NotVoidable();
    error BuyNowNotAvailable();
    error BidExceedsBuyNowPrice();
    error AuctionHasBids();
    error CannotWithdrawHighestBid();
    error NotABidder();
    error InvalidBidIndex();

    /* -------------------------------------------------------------------------- */
    /*                                  CONSTANTS                                 */
    /* -------------------------------------------------------------------------- */

    // WARNING: This value is hardcoded into the Auction struct's storage layout.
    // Changing it in future versions will cause storage collisions and break any
    // proxy-based upgrades, leading to critical state corruption.
    // DO NOT CHANGE THIS VALUE.
    uint8 private constant TOP_BIDS_COUNT = 10;

    /// @dev escrow grace period after auction end (seconds). Can be updated by owner.
    uint64 public escrowPeriod = 6 days;

    /* -------------------------------------------------------------------------- */
    /*                                 DATA MODEL                                 */
    /* -------------------------------------------------------------------------- */

    enum AuctionStatus {
        Active,     // Bidding is open or settlement is in progress.
        Settled,    // The auction concluded successfully with an asset swap.
        Voided,     // A party defaulted post-bidding; assets returned.
        Cancelled   // The seller cancelled the auction before any bids were placed.
    }

    struct Bid {
        address bidder;
        uint128 amount;
        uint64 timestamp;
    }

    struct Auction {
        // immutable listing data
        address   seller;
        IERC721   nft;
        uint256   tokenId;
        IERC20    payToken;
        uint128   minBid;
        uint128   buyNowPrice;      // 0 = disabled; kept for completeness
        uint64    biddingEnd;

        // dynamic bidding data
        address   highestBidder;
        uint128   highestBid;
        Bid[TOP_BIDS_COUNT] topBids;

        // escrow phase
        bool      nftDeposited;
        bool      fundsDeposited;

        AuctionStatus status;
    }

    mapping(uint256 => Auction) public auctions;
    uint256 public auctionCount;

    /* -------------------------------------------------------------------------- */
    /*                                    EVENTS                                  */
    /* -------------------------------------------------------------------------- */

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nft,
        uint256 tokenId,
        address payToken,
        uint256 minBid,
        uint128 buyNowPrice,
        uint256 biddingEnd
    );

    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );

    event BidWithdrawn(uint256 indexed auctionId, address indexed bidder, uint256 amount);

    event NFTDeposited(uint256 indexed auctionId);
    event FundsDeposited(uint256 indexed auctionId);

    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed buyer,
        uint256 amount
    );

    event AuctionCancelled(uint256 indexed auctionId);
    event AuctionVoided(uint256 indexed auctionId);

    event AuctionPurchased(uint256 indexed auctionId, address indexed buyer, uint256 price);

    event AuctionEndedBySeller(uint256 indexed auctionId, address indexed winner, uint256 price);

    event EscrowPeriodUpdated(uint64 oldPeriod, uint64 newPeriod);

    /* -------------------------------------------------------------------------- */
    /*                                   ADMIN                                    */
    /* -------------------------------------------------------------------------- */

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setEscrowPeriod(uint64 newPeriod) external onlyOwner {
        uint64 old = escrowPeriod;
        escrowPeriod = newPeriod;
        emit EscrowPeriodUpdated(old, newPeriod);
    }

    /* -------------------------------------------------------------------------- */
    /*                                MAIN LOGIC                                  */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice List a property-NFT for auction (NFT stays in wallet for now).
     * @param nft          ERC-721 collection
     * @param tokenId      NFT id
     * @param payToken     ERC-20 used for payment (e.g., USDC)
     * @param minBid       Minimum acceptable first bid (must > 0)
     * @param duration     Auction length in seconds
     */
    function createAuction(
        IERC721 nft,
        uint256 tokenId,
        IERC20  payToken,
        uint128 minBid,
        uint64  duration,
        uint128 buyNowPrice
    ) external whenNotPaused nonReentrant returns (uint256 auctionId) {
        if (
            address(nft) == address(0) ||
            address(payToken) == address(0) ||
            minBid == 0 ||
            duration == 0 ||
            (buyNowPrice != 0 && buyNowPrice <= minBid)
        ) revert InvalidParams();

        unchecked { auctionId = ++auctionCount; }

        auctions[auctionId] = Auction({
            seller: msg.sender,
            nft: nft,
            tokenId: tokenId,
            payToken: payToken,
            minBid: minBid,
            buyNowPrice: buyNowPrice,
            biddingEnd: uint64(block.timestamp) + duration,
            highestBidder: address(0),
            highestBid: 0,
            nftDeposited: false,
            fundsDeposited: false,
            status: AuctionStatus.Active
        });

        emit AuctionCreated(
            auctionId,
            msg.sender,
            address(nft),
            tokenId,
            address(payToken),
            minBid,
            buyNowPrice,
            uint64(block.timestamp) + duration
        );
    }

    /**
     * @notice Place an on-chain bid (no funds pulled yet).
     * @param auctionId auction id
     * @param amount    bid amount (must beat current by +1)
     */
    function placeBid(uint256 auctionId, uint128 amount)
        external
        whenNotPaused
        nonReentrant
    {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Active) revert AuctionNotActive();
        if (block.timestamp >= a.biddingEnd) revert AuctionExpired();
        if (a.buyNowPrice > 0 && amount >= a.buyNowPrice) revert BidExceedsBuyNowPrice();

        uint256 required =
            (a.highestBid == 0) ? uint256(a.minBid) : uint256(a.highestBid) + 1;
        if (amount < required) revert BidTooLow(required);

        // Shift existing bids down to make space for the new top bid.
        for (uint8 i = TOP_BIDS_COUNT - 1; i > 0; --i) {
            a.topBids[i] = a.topBids[i - 1];
        }

        // Insert the new highest bid at the top of the array
        a.topBids[0] = Bid({bidder: msg.sender, amount: amount, timestamp: uint64(block.timestamp)});

        // Update the auction's primary winner and bid amount.
        a.highestBidder = msg.sender;
        a.highestBid = amount;

        emit BidPlaced(auctionId, msg.sender, amount);
    }

    /**
     * @notice Withdraw a bid from an auction.
     * @dev Allows any bidder, except the current highest, to withdraw their bid.
     *      This prevents price manipulation (e.g., "bid chilling") by making the
     *      highest bid a firm commitment. It also allows outbid participants to
     *      opt-out of being promoted to winner if the top bidder defaults.
     * @param auctionId The ID of the auction.
     */
    function withdrawBid(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Active) revert AuctionNotActive();
        if (block.timestamp >= a.biddingEnd) revert AuctionExpired();

        // Find the bidder's bid in the top bids
        uint8 bidIndex = TOP_BIDS_COUNT; // Use count as a sentinel for "not found"
        uint128 withdrawnAmount = 0;
        for (uint8 i = 0; i < TOP_BIDS_COUNT; i++) {
            if (a.topBids[i].bidder == msg.sender) {
                bidIndex = i;
                withdrawnAmount = a.topBids[i].amount;
                break;
            }
        }

        if (bidIndex == TOP_BIDS_COUNT) revert NotABidder();
        if (bidIndex == 0) revert CannotWithdrawHighestBid();

        // Remove the bid by shifting lower bids up
        for (uint8 i = bidIndex; i < TOP_BIDS_COUNT - 1; i++) {
            a.topBids[i] = a.topBids[i + 1];
        }
        // Clear the last spot
        delete a.topBids[TOP_BIDS_COUNT - 1];

        emit BidWithdrawn(auctionId, msg.sender, withdrawnAmount);
    }

    /**
     * @notice Purchase the NFT immediately at its "Buy Now" price.
     * @dev This is only possible before any bids are placed.
     *      The buyer's funds are escrowed, and the auction ends. The seller
     *      must then deposit the NFT to trigger settlement.
     * @param auctionId The ID of the auction to purchase.
     */
    function buyNow(uint256 auctionId) external whenNotPaused nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Active) revert AuctionNotActive();
        if (block.timestamp >= a.biddingEnd) revert AuctionExpired();
        if (a.buyNowPrice == 0) revert BuyNowNotAvailable();
        if (a.highestBid != 0) revert BuyNowNotAvailable();

        // Set winner and price
        a.highestBidder = msg.sender;
        a.highestBid = a.buyNowPrice;

        // End auction
        a.biddingEnd = uint64(block.timestamp);

        // Escrow funds from buyer
        a.fundsDeposited = true;
        a.payToken.safeTransferFrom(msg.sender, address(this), a.buyNowPrice);

        emit AuctionPurchased(auctionId, msg.sender, a.buyNowPrice);
        emit FundsDeposited(auctionId);
    }

    /**
     * @notice Seller can accept a bid to end the auction early.
     * @dev Moves the auction to the settlement phase. The chosen bidder becomes the winner.
     * @param auctionId The ID of the auction.
     * @param bidIndex The index (0-4) of the bid to accept from the top bids list.
     */
    function acceptBid(uint256 auctionId, uint256 bidIndex) external nonReentrant {
        Auction storage a = auctions[auctionId];
        
        // --- Validation ---
        if (a.status != AuctionStatus.Active) revert AuctionNotActive();
        if (msg.sender != a.seller) revert NotSeller();
        if (block.timestamp >= a.biddingEnd) revert AuctionExpired();
        if (bidIndex >= TOP_BIDS_COUNT) revert InvalidBidIndex();

        Bid storage acceptedBid = a.topBids[bidIndex];
        if (acceptedBid.bidder == address(0)) revert InvalidBidIndex(); // Cannot accept an empty bid slot

        // --- State Changes ---
        // Set the winner and final price from the accepted bid
        a.highestBidder = acceptedBid.bidder;
        a.highestBid = acceptedBid.amount;

        // End the auction bidding period immediately
        a.biddingEnd = uint64(block.timestamp);

        // --- Events ---
        emit AuctionEndedBySeller(auctionId, a.highestBidder, a.highestBid);
    }

    /* -------------------------------- ESCROW ---------------------------------- */

    /** @notice Seller escrows the NFT **after** auctionEnd. */
    function depositNFT(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Active) revert AuctionNotActive();
        if (msg.sender != a.seller) revert NotSeller();
        if (a.nftDeposited) revert NFTAlreadyDeposited();
        if (block.timestamp < a.biddingEnd) revert AuctionActive();
        if (a.highestBidder == address(0)) revert AuctionExpired(); // no bids

        a.nftDeposited = true;
        a.nft.safeTransferFrom(msg.sender, address(this), a.tokenId);

        emit NFTDeposited(auctionId);
        _trySettle(auctionId);
    }

    /** @notice Winner escrows funds **after** auctionEnd. */
    function depositFunds(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Active) revert AuctionNotActive();
        if (msg.sender != a.highestBidder) revert NotWinner();
        if (a.fundsDeposited) revert FundsAlreadyDeposited();
        if (block.timestamp < a.biddingEnd) revert AuctionActive();

        a.fundsDeposited = true;
        a.payToken.safeTransferFrom(msg.sender, address(this), a.highestBid);

        emit FundsDeposited(auctionId);
        _trySettle(auctionId);
    }

    /** @dev Attempt atomic settlement when both escrow legs are present. */
    function _trySettle(uint256 auctionId) private {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Active) return;
        if (!a.nftDeposited || !a.fundsDeposited) return;

        // funds → seller
        a.payToken.safeTransfer(a.seller, a.highestBid);
        // NFT → buyer
        a.nft.safeTransferFrom(address(this), a.highestBidder, a.tokenId);

        a.status = AuctionStatus.Settled;
        emit AuctionSettled(auctionId, a.highestBidder, a.highestBid);
    }

    /* --------------------------- DEFAULT / VOID PATH -------------------------- */

    /**
     * @notice After `escrowPeriod`, either party may void if the other leg
     *         has not been deposited. Deposited assets are returned.
     */
    function voidAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Active) revert AuctionNotActive();
        if (block.timestamp < a.biddingEnd + escrowPeriod) revert NotVoidable();

        // Only allow:
        //  – seller to void if buyer hasn't deposited funds
        //  – winner to void if seller hasn't deposited NFT
        if (
            (msg.sender == a.seller        && !a.fundsDeposited) ||
            (msg.sender == a.highestBidder && !a.nftDeposited)
        ) {
            // Return any deposited asset
            if (a.fundsDeposited) {
                a.payToken.safeTransfer(a.highestBidder, a.highestBid);
            }
            if (a.nftDeposited) {
                a.nft.safeTransferFrom(address(this), a.seller, a.tokenId);
            }

            a.status = AuctionStatus.Voided;
            emit AuctionVoided(auctionId);
        } else {
            revert NotVoidable();
        }
    }

    /* -------------------------- EARLY CANCEL (NO BIDS) ------------------------- */

    /** @notice Seller can cancel before the first bid and before endTime. */
    // To protect bidders, an auction becomes a binding commitment once the first bid is placed.
    function cancelAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Active) revert AuctionNotActive();
        if (msg.sender != a.seller) revert NotSeller();
        if (a.highestBidder != address(0)) revert AuctionHasBids();
        if (block.timestamp >= a.biddingEnd) revert AuctionExpired();

        a.status = AuctionStatus.Cancelled;
        emit AuctionCancelled(auctionId);
    }

    /* -------------------------------------------------------------------------- */
    /*                              VIEW FUNCTIONS                                */
    /* -------------------------------------------------------------------------- */

    function isSettleable(uint256 auctionId) external view returns (bool) {
        Auction storage a = auctions[auctionId];
        return
            a.status == AuctionStatus.Active &&
            a.nftDeposited &&
            a.fundsDeposited;
    }

    /* -------------------------------------------------------------------------- */
    /*                           ERC-721 RECEIVER HOOK                            */
    /* -------------------------------------------------------------------------- */

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        // Just accept – further checks are done in depositNFT
        return IERC721Receiver.onERC721Received.selector;
    }
}
