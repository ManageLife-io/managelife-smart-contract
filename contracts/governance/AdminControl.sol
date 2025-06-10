// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/// @title AdminControl - Administrative control and role management for the platform
/// @notice Manages roles, fees, rewards, and administrative functions
/// @dev Inherits from AccessControl for role-based permissions
contract AdminControl is AccessControl, ReentrancyGuard, Pausable {
    // ========== Role Definitions ==========
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant LEGAL_ROLE = keccak256("LEGAL_ROLE");
    bytes32 public constant REWARD_MANAGER = keccak256("REWARD_MANAGER");
    bytes32 public constant EMERGENCY_ADMIN = keccak256("EMERGENCY_ADMIN");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ========== State Variables ==========
    struct FeeConfig {
        uint256 baseFee;
        uint256 maxFee;
        uint256 minFee;
        address feeCollector;
        uint256 lastUpdateTime;
    }

    struct RewardParameters {
        uint256 baseRate;
        uint256 multiplier;
        uint256 rewardsCap;
        uint256 lastUpdateTime;
        address rewardsVault;
    }

    FeeConfig public feeConfig;
    RewardParameters public rewardParams;
    
    // KYC and Community Score Management
    mapping(address => bool) private _kycVerified;
    mapping(address => uint256) public communityScores;
    
    // Constants
    uint256 public constant MAX_BASE_RATE = 1000000; // 100% with 4 decimals
    uint256 public constant MIN_BASE_RATE = 100; // 0.01% with 4 decimals
    uint256 public constant MAX_MULTIPLIER = 10000; // 10x
    uint256 public constant MIN_MULTIPLIER = 100; // 0.1x
    uint256 public constant MAX_COMMUNITY_SCORE = 10000; // 100% with 2 decimals
    uint256 public constant PERCENTAGE_BASE = 10000; // 100% = 10000
    uint256 public constant MAX_FEE = 1000; // 10% with 2 decimals
    uint256 public constant MIN_UPDATE_INTERVAL = 1 days;

    // ========== Events ==========
    event FeeConfigUpdated(
        uint256 oldBaseFee,
        uint256 newBaseFee,
        uint256 oldMaxFee,
        uint256 newMaxFee,
        uint256 oldMinFee,
        uint256 newMinFee,
        address indexed admin
    );
    
    event RewardParametersUpdated(
        uint256 oldBaseRate,
        uint256 newBaseRate,
        uint256 oldMultiplier,
        uint256 newMultiplier,
        uint256 oldCap,
        uint256 newCap,
        address indexed admin
    );
    
    event KYCStatusUpdated(address indexed account, bool status, address indexed operator);
    event CommunityScoreUpdated(address indexed account, uint256 oldScore, uint256 newScore);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event RewardsVaultUpdated(address indexed oldVault, address indexed newVault);
    event AdminRoleGranted(bytes32 indexed role, address indexed account, address indexed admin);
    event AdminRoleRevoked(bytes32 indexed role, address indexed account, address indexed admin);

    // ========== Constructor ==========
    constructor(
        address initialAdmin,
        address feeCollector,
        address rewardsVault
    ) {
        require(initialAdmin != address(0), "Invalid admin address");
        require(feeCollector != address(0), "Invalid fee collector");
        require(rewardsVault != address(0), "Invalid rewards vault");

        _setupRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _setupRole(OPERATOR_ROLE, initialAdmin);
        _setupRole(LEGAL_ROLE, initialAdmin);
        _setupRole(REWARD_MANAGER, initialAdmin);
        _setupRole(EMERGENCY_ADMIN, initialAdmin);
        _setupRole(PAUSER_ROLE, initialAdmin);

        feeConfig = FeeConfig({
            baseFee: 250, // 2.5%
            maxFee: 500,  // 5%
            minFee: 100,  // 1%
            feeCollector: feeCollector,
            lastUpdateTime: block.timestamp
        });

        rewardParams = RewardParameters({
            baseRate: 1000,  // 10%
            multiplier: 200, // 2x
            rewardsCap: 1000000 * 10**18, // 1M tokens
            lastUpdateTime: block.timestamp,
            rewardsVault: rewardsVault
        });
    }

    // ========== Modifiers ==========
    modifier onlyValidAddress(address account) {
        require(account != address(0), "Invalid address");
        _;
    }

    modifier onlyAfterInterval() {
        require(
            block.timestamp >= feeConfig.lastUpdateTime + MIN_UPDATE_INTERVAL,
            "Update interval not elapsed"
        );
        _;
    }

    // ========== Role Management ==========
    function grantRole(bytes32 role, address account)
        public
        override
        onlyRole(getRoleAdmin(role))
        onlyValidAddress(account)
    {
        super.grantRole(role, account);
        emit AdminRoleGranted(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account)
        public
        override
        onlyRole(getRoleAdmin(role))
        onlyValidAddress(account)
    {
        super.revokeRole(role, account);
        emit AdminRoleRevoked(role, account, msg.sender);
    }

    // ========== Fee Management ==========
    function updateFeeConfig(
        uint256 newBaseFee,
        uint256 newMaxFee,
        uint256 newMinFee
    )
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        onlyAfterInterval
    {
        require(newMinFee <= newBaseFee, "Min fee exceeds base fee");
        require(newBaseFee <= newMaxFee, "Base fee exceeds max fee");
        require(newMaxFee <= MAX_FEE, "Max fee too high");

        emit FeeConfigUpdated(
            feeConfig.baseFee,
            newBaseFee,
            feeConfig.maxFee,
            newMaxFee,
            feeConfig.minFee,
            newMinFee,
            msg.sender
        );

        feeConfig.baseFee = newBaseFee;
        feeConfig.maxFee = newMaxFee;
        feeConfig.minFee = newMinFee;
        feeConfig.lastUpdateTime = block.timestamp;
    }

    function updateFeeCollector(address newCollector)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        onlyValidAddress(newCollector)
    {
        address oldCollector = feeConfig.feeCollector;
        feeConfig.feeCollector = newCollector;
        emit FeeCollectorUpdated(oldCollector, newCollector);
    }

    // ========== Reward Management ==========
    function updateRewardParameters(
        uint256 newBaseRate,
        uint256 newMultiplier,
        uint256 newRewardsCap
    )
        external
        onlyRole(REWARD_MANAGER)
        whenNotPaused
        onlyAfterInterval
    {
        require(newBaseRate >= MIN_BASE_RATE, "Base rate too low");
        require(newBaseRate <= MAX_BASE_RATE, "Base rate too high");
        require(newMultiplier >= MIN_MULTIPLIER, "Multiplier too low");
        require(newMultiplier <= MAX_MULTIPLIER, "Multiplier too high");

        emit RewardParametersUpdated(
            rewardParams.baseRate,
            newBaseRate,
            rewardParams.multiplier,
            newMultiplier,
            rewardParams.rewardsCap,
            newRewardsCap,
            msg.sender
        );

        rewardParams.baseRate = newBaseRate;
        rewardParams.multiplier = newMultiplier;
        rewardParams.rewardsCap = newRewardsCap;
        rewardParams.lastUpdateTime = block.timestamp;
    }

    function updateRewardsVault(address newVault)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        onlyValidAddress(newVault)
    {
        address oldVault = rewardParams.rewardsVault;
        rewardParams.rewardsVault = newVault;
        emit RewardsVaultUpdated(oldVault, newVault);
    }

    // ========== KYC Management ==========
    function updateKYCStatus(address account, bool status)
        external
        onlyRole(LEGAL_ROLE)
        whenNotPaused
        onlyValidAddress(account)
    {
        _kycVerified[account] = status;
        emit KYCStatusUpdated(account, status, msg.sender);
    }

    function isKYCVerified(address account) public view returns (bool) {
        return _kycVerified[account];
    }

    // ========== Community Score Management ==========
    function updateCommunityScore(address account, uint256 newScore)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        onlyValidAddress(account)
    {
        require(newScore <= MAX_COMMUNITY_SCORE, "Score exceeds maximum");
        uint256 oldScore = communityScores[account];
        communityScores[account] = newScore;
        emit CommunityScoreUpdated(account, oldScore, newScore);
    }

    // ========== Emergency Controls ==========
    function pause() external onlyRole(EMERGENCY_ADMIN) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ADMIN) {
        _unpause();
    }

    // ========== View Functions ==========
    function getFeeConfig() external view returns (
        uint256 baseFee,
        uint256 maxFee,
        uint256 minFee,
        address collector,
        uint256 lastUpdate
    ) {
        return (
            feeConfig.baseFee,
            feeConfig.maxFee,
            feeConfig.minFee,
            feeConfig.feeCollector,
            feeConfig.lastUpdateTime
        );
    }

    function getRewardParameters() external view returns (
        uint256 baseRate,
        uint256 multiplier,
        uint256 rewardsCap,
        address vault,
        uint256 lastUpdate
    ) {
        return (
            rewardParams.baseRate,
            rewardParams.multiplier,
            rewardParams.rewardsCap,
            rewardParams.rewardsVault,
            rewardParams.lastUpdateTime
        );
    }
}
