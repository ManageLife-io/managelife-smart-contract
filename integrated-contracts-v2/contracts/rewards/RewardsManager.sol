// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title RewardsManager
/// @notice Centralized rewards distribution contract for ManageLife stakeholders
/// @dev Holds $MLife tokens and distributes according to basis-point rules. Uses operator gating
contract RewardsManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant REWARD_MANAGER = keccak256("REWARD_MANAGER");

    // Token
    IERC20 public immutable lifeToken;

    // Constants
    uint256 public constant BPS_DENOMINATOR = 10_000; // 100% = 10000 bps
    uint256 public constant MONTH_SECONDS = 30 days; // simplified month bucket
    // Timelock governance
    address public timelock;
    event TimelockSet(address indexed oldTimelock, address indexed newTimelock);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);


    // Default rates (bps)
    struct Rates {
        uint16 renterCashbackBps;       // 10% on rent (SC)
        uint16 ownerRentTopUpBps;       // 10% top-up when occupied (SC)
        uint16 ownerContribTopUpBps;    // 15% top-up when contributed (SC)
        uint16 buyerPurchaseRewardBps;  // 1% of purchase price (MP)
        uint16 buyerTxRebateBps;        // 1% of tx cost if MLIFE used (MP)
        uint16 referralMinBps;          // 1%
        uint16 referralMaxBps;          // 2%
        uint256 monthlyGasRebate;       // 100 MLIFE (18 decimals)
    }

    Rates public rates;

    // Claim guards
    mapping(address => uint64) public lastGasRebateMonth; // homeowner => last month index
    mapping(bytes32 => bool) public claimUsed;            // idempotency per-award-type using namespaced keys

    // Events
    event GasRebateAwarded(address indexed homeowner, uint256 monthIndex, uint256 amount);
    event RenterCashbackAwarded(address indexed renter, bytes32 indexed paymentId, uint256 rentPaid, uint256 reward);
    event OwnerRentTopUpAwarded(address indexed owner, bytes32 indexed paymentId, bool contributed, uint256 rentAmount, uint256 reward);
    event BuyerRewardAwarded(address indexed buyer, bytes32 indexed purchaseId, uint256 purchasePrice, uint256 purchaseReward, uint256 txRebate);
    event ReferralAwarded(address indexed referrer, bytes32 indexed referralId, uint256 baseAmount, uint16 bps, uint256 reward);
    event EngagementAwarded(address indexed user, bytes32 indexed engagementId, uint256 baseAmount, uint16 bps, uint256 reward);
    event RatesUpdated(Rates newRates);
    event TokensFunded(address indexed from, uint256 amount);
    event TokensRescued(address indexed to, uint256 amount);

    constructor(address _lifeToken, address admin) {
        require(_lifeToken != address(0), "Invalid token");
        require(admin != address(0), "Invalid admin");
        lifeToken = IERC20(_lifeToken);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REWARD_MANAGER, admin);

        // Set sensible defaults (values in bps)
        rates = Rates({
            renterCashbackBps: 1000,       // 10%
            ownerRentTopUpBps: 1000,       // 10%
            ownerContribTopUpBps: 1500,    // 15%
            buyerPurchaseRewardBps: 100,   // 1%
            buyerTxRebateBps: 100,         // 1%

    modifier onlyTimelock() {
        require(msg.sender == timelock, "Timelock required");
        _;
    }

    /// @notice Set the TimelockController address that must execute sensitive operations
    /// @dev Can be set once by DEFAULT_ADMIN_ROLE; subsequent updates must be performed by the timelock itself
    function setTimelock(address newTimelock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTimelock != address(0), "Invalid timelock");
        address old = timelock;
        if (old != address(0)) {
            require(msg.sender == old, "Only timelock can change");
        }
        timelock = newTimelock;
        emit TimelockSet(old, newTimelock);
    }

            referralMinBps: 100,           // 1%
            referralMaxBps: 200,           // 2%
            monthlyGasRebate: 100 ether    // 100 MLIFE (18 decimals)
        });
    }

    // ========================= Key Namespacing =========================
    function _ns(bytes32 tag, bytes32 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(tag, id));
    }

    bytes32 private constant TAG_RENTER = keccak256("RENTER");
    bytes32 private constant TAG_OWNER_TOPUP = keccak256("OWNER_TOPUP");
    bytes32 private constant TAG_BUYER = keccak256("BUYER");
    bytes32 private constant TAG_REFERRAL = keccak256("REFERRAL");
    bytes32 private constant TAG_ENGAGE = keccak256("ENGAGE");

    /// @notice Transfer DEFAULT_ADMIN_ROLE and REWARD_MANAGER role to a new admin (governance-controlled)
    /// @dev Only callable by timelock to enforce multisig/governance control
    function setAdmin(address newAdmin) external onlyTimelock {
        require(newAdmin != address(0), "zero admin");
        // Find an existing admin to revoke; for simplicity, revoke msg.sender if it has admin, and grant new one
        // In practice, governance can manage roles externally too.
        address previousAdmin = address(0);
        // NOTE: AccessControl does not expose enumeration by default; previous admin tracking is off-chain
        // We emit event with previousAdmin as 0 if unknown.
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _grantRole(REWARD_MANAGER, newAdmin);
        emit AdminTransferred(previousAdmin, newAdmin);
    }



    // ========================= Admin =========================
    function setRates(Rates calldata newRates) external onlyTimelock {
        require(newRates.referralMinBps <= newRates.referralMaxBps, "ref bps range");
        require(newRates.renterCashbackBps <= BPS_DENOMINATOR, "renter bps");
        require(newRates.ownerRentTopUpBps <= BPS_DENOMINATOR, "owner bps");
        require(newRates.ownerContribTopUpBps <= BPS_DENOMINATOR, "owner contrib bps");
        require(newRates.buyerPurchaseRewardBps <= BPS_DENOMINATOR, "buyer bps");
        require(newRates.buyerTxRebateBps <= BPS_DENOMINATOR, "tx bps");
        rates = newRates;
        emit RatesUpdated(newRates);
    }

    function fund(uint256 amount) external nonReentrant {
        lifeToken.safeTransferFrom(msg.sender, address(this), amount);
        emit TokensFunded(msg.sender, amount);
    }

    function rescue(address to, uint256 amount) external onlyTimelock {
        lifeToken.safeTransfer(to, amount);
        emit TokensRescued(to, amount);
    }

    // ========================= Award Functions =========================
    /// @notice Gas rebate to Homeowner for listing/tokenizing, once per calendar month bucket
    function awardHomeownerGasRebate(address homeowner) external onlyRole(REWARD_MANAGER) nonReentrant {
        require(homeowner != address(0), "zero addr");
        uint64 monthIndex = uint64(block.timestamp / MONTH_SECONDS);
        require(lastGasRebateMonth[homeowner] < monthIndex, "already claimed");
        lastGasRebateMonth[homeowner] = monthIndex;
        lifeToken.safeTransfer(homeowner, rates.monthlyGasRebate);
        emit GasRebateAwarded(homeowner, monthIndex, rates.monthlyGasRebate);
    }

    /// @notice Renter: 10% $MLife back on every rent payment (SC)
    function awardRenterRentCashback(address renter, uint256 rentPaid, bytes32 paymentId) external onlyRole(REWARD_MANAGER) nonReentrant {
        require(!claimUsed[paymentId], "claimed");
        require(renter != address(0) && rentPaid > 0, "bad args");
        claimUsed[paymentId] = true;
        uint256 reward = (rentPaid * rates.renterCashbackBps) / BPS_DENOMINATOR;
        lifeToken.safeTransfer(renter, reward);
        emit RenterCashbackAwarded(renter, paymentId, rentPaid, reward);
    }

    /// @notice Homeowner/Portfolio Manager: 10% on top of rent income when occupied; 15% if contributed (SC)
    function awardOwnerRentTopUp(address owner, uint256 rentAmount, bool contributed, bytes32 paymentId) external onlyRole(REWARD_MANAGER) nonReentrant {
        require(!claimUsed[paymentId], "claimed");
        require(owner != address(0) && rentAmount > 0, "bad args");
        claimUsed[paymentId] = true;
        uint16 bps = contributed ? rates.ownerContribTopUpBps : rates.ownerRentTopUpBps;
        uint256 reward = (rentAmount * bps) / BPS_DENOMINATOR;
        lifeToken.safeTransfer(owner, reward);
        emit OwnerRentTopUpAwarded(owner, paymentId, contributed, rentAmount, reward);
    }

    /// @notice Buyer: 1% of purchase price; optional 1% rebate on tx cost if MLIFE used (MP-driven call)
    function awardBuyerPurchaseReward(
        address buyer,
        uint256 purchasePrice,
        uint256 txCost,
        bool mLifeUsed,
        bytes32 purchaseId
    ) external onlyRole(REWARD_MANAGER) nonReentrant {
        bytes32 key = _ns(TAG_BUYER, purchaseId);
        require(!claimUsed[key], "claimed");
        require(buyer != address(0) && purchasePrice > 0, "bad args");
        claimUsed[key] = true;
        uint256 baseReward = (purchasePrice * rates.buyerPurchaseRewardBps) / BPS_DENOMINATOR;
        uint256 txRebate = mLifeUsed ? (txCost * rates.buyerTxRebateBps) / BPS_DENOMINATOR : 0;
        uint256 total = baseReward + txRebate;
        if (total > 0) {
            lifeToken.safeTransfer(buyer, total);
        }
        emit BuyerRewardAwarded(buyer, purchaseId, purchasePrice, baseReward, txRebate);
    }

    /// @notice Referral: 1-2% on payment amount (MP)
    function awardReferral(address referrer, uint256 amount, uint16 bps, bytes32 referralId) external onlyRole(REWARD_MANAGER) nonReentrant {
        bytes32 key = _ns(TAG_REFERRAL, referralId);
        require(!claimUsed[key], "claimed");
        require(referrer != address(0) && amount > 0, "bad args");
        require(bps >= rates.referralMinBps && bps <= rates.referralMaxBps, "bps out of range");
        claimUsed[key] = true;
        uint256 reward = (amount * bps) / BPS_DENOMINATOR;
        lifeToken.safeTransfer(referrer, reward);
        emit ReferralAwarded(referrer, referralId, amount, bps, reward);
    }

    /// @notice Platform engagement: e.g., monthly tasks, bps applied on base (MP)
    function awardEngagement(address user, uint256 baseAmount, uint16 bps, bytes32 engagementId) external onlyRole(REWARD_MANAGER) nonReentrant {
        bytes32 key = _ns(TAG_ENGAGE, engagementId);
        require(!claimUsed[key], "claimed");
        require(user != address(0) && baseAmount > 0, "bad args");
        require(bps <= BPS_DENOMINATOR, "bps high");
        claimUsed[key] = true;
        uint256 reward = (baseAmount * bps) / BPS_DENOMINATOR;
        lifeToken.safeTransfer(user, reward);
        emit EngagementAwarded(user, engagementId, baseAmount, bps, reward);
    }
}

