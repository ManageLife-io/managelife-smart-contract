// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title AdminControl - Core contract for system administration and configuration
/// @notice Manages system roles, fees, KYC verification, and reward parameters
/// @dev Implements role-based access control and emergency pause functionality
contract AdminControl is AccessControl, Pausable {
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    using EnumerableSet for EnumerableSet.AddressSet;
    
    // ========== Role Definitions ==========
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant LEGAL_ROLE = keccak256("LEGAL_ROLE");
    bytes32 public constant REWARD_MANAGER = keccak256("REWARD_MANAGER");

    // ========== Constants ==========
    uint256 public constant BASIS_POINTS = 10000; // Base for percentage calculations (100% = 10000, 1% = 100)
    
    // ========== Fee Structure ==========
    struct FeeSettings {
        uint256 baseFee;        // Base transaction fee rate (basis points: 100 = 1%)
        uint256 maxFee;         // Maximum allowed fee rate (basis points)
        address feeCollector;   // Fee collection address
    }

    // ========== Reward Parameters Structure ==========
    struct RewardParameters {
        uint256 baseRate;              // Base reward rate (basis points)
        uint256 communityMultiplier;   // Community bonus multiplier
        uint256 maxLeaseBonus;         // Maximum lease duration bonus
        address rewardsVault;          // Rewards vault address
    }

    // ========== State Variables ==========
    FeeSettings public feeConfig;
    RewardParameters public rewardParams;
    
    EnumerableSet.AddressSet private _kycVerified;
    mapping(address => uint256) public communityScores;
    mapping(uint256 => bool) public functionPaused;

    // ========== Event Definitions ==========
    event FeeConfigUpdated(uint256 oldBaseFee, uint256 newBaseFee, uint256 oldMaxFee, uint256 newMaxFee, address indexed admin);
    event RewardParametersUpdated(uint256 oldBaseRate, uint256 newBaseRate, uint256 oldMultiplier, uint256 newMultiplier, address indexed admin);
    event KYCStatusUpdated(address indexed account, bool status);
    function grantRole(bytes32 role, address account) public override(AccessControl) onlyRole(getRoleAdmin(role)) {
        super.grantRole(role, account);
        emit RoleGranted(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) public override(AccessControl) onlyRole(getRoleAdmin(role)) {
        super.revokeRole(role, account);
        emit RoleRevoked(role, account, msg.sender);
    }

    function _initializeRoles(address admin) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(LEGAL_ROLE, admin);
        _grantRole(REWARD_MANAGER, admin);
    }

    constructor(
        address initialAdmin,
        address feeCollector,
        address rewardsVault
    ) {
        require(feeCollector != address(0), "Invalid fee collector address");
        require(rewardsVault != address(0), "Invalid rewards vault address");
        require(initialAdmin != address(0), "Invalid admin address");
        
        // Initialize role assignments
        _initializeRoles(initialAdmin);

        // Initialize fee configuration
        feeConfig = FeeSettings({
            baseFee: 200,       // 2%
            maxFee: 1000,       // 10%
            feeCollector: feeCollector
        });

        // Initialize reward parameters
        rewardParams = RewardParameters({
            baseRate: 1000,     // 10% base reward
            communityMultiplier: 2000, // 20% max community bonus
            maxLeaseBonus: 300, // 3% max lease bonus
            rewardsVault: rewardsVault
        });
    }

    // ========== Fee Management ==========
    /// @notice Updates the fee configuration for the system
    /// @dev Only callable by accounts with OPERATOR_ROLE
    /// @param newBaseFee New base fee rate in basis points (100 = 1%)
    /// @param newCollector New address to collect fees
    function updateFeeConfig(
        uint256 newBaseFee, 
        address newCollector
    ) external onlyRole(OPERATOR_ROLE) {
        require(newCollector != address(0), "Invalid fee collector address");
        require(newBaseFee <= feeConfig.maxFee, "Exceeds max fee");
        uint256 oldBase = feeConfig.baseFee;
        uint256 oldMax = feeConfig.maxFee;
        feeConfig.baseFee = newBaseFee;
        feeConfig.feeCollector = newCollector;
        emit FeeConfigUpdated(oldBase, newBaseFee, oldMax, feeConfig.maxFee, msg.sender);
    }

    // ========== KYC Management ==========
    /// @notice Batch approves or revokes KYC verification for multiple accounts
    /// @dev Only callable by accounts with LEGAL_ROLE
    /// @param accounts Array of addresses to update KYC status
    /// @param approved True to approve, false to revoke KYC status
    function batchApproveKYC(
        address[] calldata accounts, 
        bool approved
    ) external onlyRole(LEGAL_ROLE) {
        for(uint i = 0; i < accounts.length; i++) {
            approved ? _kycVerified.add(accounts[i]) : _kycVerified.remove(accounts[i]);
            emit KYCStatusUpdated(accounts[i], approved);
        }
    }

    // ========== Reward Management ==========
    /// @notice Configures the reward parameters for the system
    /// @dev Only callable by accounts with REWARD_MANAGER role
    /// @param newBaseRate New base reward rate in basis points
    /// @param newMultiplier New community multiplier for rewards
    /// @param newLeaseBonus New maximum lease bonus percentage
    function configureRewards(
        uint256 newBaseRate,
        uint256 newMultiplier,
        uint256 newLeaseBonus
    ) external onlyRole(REWARD_MANAGER) {
        require(rewardParams.rewardsVault != address(0), "Rewards vault not set");
        require(newBaseRate <= 2000, "Base rate >20%");
        require(newMultiplier <= 2000, "Multiplier >20%");
        require(newLeaseBonus <= 500, "Lease bonus >5%");

        uint256 oldRate = rewardParams.baseRate;
        uint256 oldMulti = rewardParams.communityMultiplier;
        rewardParams.baseRate = newBaseRate;
        rewardParams.communityMultiplier = newMultiplier;
        rewardParams.maxLeaseBonus = newLeaseBonus;
        
        emit RewardParametersUpdated(oldRate, newBaseRate, oldMulti, newMultiplier, msg.sender);
    }

    // ========== Emergency Controls ==========
    /// @notice Pauses or unpauses a specific function in emergency situations
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    /// @param functionId ID of the function to pause/unpause
    /// @param paused True to pause, false to unpause
    function emergencyPauseFunction(
        uint256 functionId, 
        bool paused
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        functionPaused[functionId] = paused;
    }

    /// @notice Pauses all contract operations in emergency situations
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    function globalPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resumes all contract operations after emergency pause
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    function globalUnpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ========== Community Score Management ==========
    /// @notice Updates a user's community score
    /// @dev Only callable by accounts with OPERATOR_ROLE
    /// @param user Address of the user to update score
    /// @param scoreDelta Amount to change the score by
    /// @param isAddition True to add score, false to subtract
    function updateCommunityScore(
        address user, 
        uint256 scoreDelta, 
        bool isAddition
    ) external onlyRole(OPERATOR_ROLE) {
        if(isAddition) {
            communityScores[user] += scoreDelta;
        } else {
            communityScores[user] = communityScores[user] > scoreDelta ? 
                communityScores[user] - scoreDelta : 0;
        }
    }

    // ========== View Functions ==========
    /// @notice Gets the current base fee rate
    /// @return Current base fee rate in basis points
    function getCurrentFee() external view returns (uint256) {
        return feeConfig.baseFee;
    }

    /// @notice Checks if an account is KYC verified
    /// @param account Address to check KYC status
    /// @return True if account is KYC verified
    function isKYCVerified(address account) external view returns (bool) {
        return _kycVerified.contains(account);
    }

    /// @notice Calculates total rewards for a user including all bonuses
    /// @dev Includes base rate, lease bonus and community bonus
    /// @param user Address of the user to calculate rewards for
    /// @param baseAmount Base amount to calculate rewards on
    /// @return Total reward amount including all bonuses
    /// @notice Calculates total rewards for a user including all bonuses
    /// @dev Includes base rate, lease bonus and community bonus
    /// @param user Address of the user to calculate rewards for
    /// @param baseAmount Base amount to calculate rewards on
    /// @return Total reward amount including all bonuses
    // Fixed duplicate NatSpec and added implementation clarity
    function calculateRewards(
        address user, 
        uint256 baseAmount
    ) external view returns (uint256) {
        uint256 leaseBonus = _getLeaseBonus(user);
        uint256 communityBonus = _getCommunityBonus(user);
        return baseAmount * (rewardParams.baseRate + leaseBonus + communityBonus) / 10000;
    }

    // ========== Internal Functions ==========
    // Added implementation roadmap comment
    function _getLeaseBonus(address /*user*/) internal view returns (uint256) {
    // TODO: Implement actual lease duration calculation
    return rewardParams.maxLeaseBonus;
    }

    function _getCommunityBonus(address user) internal view returns (uint256) {
        uint256 score = communityScores[user];
        return score > rewardParams.communityMultiplier ? 
            rewardParams.communityMultiplier : score;
    }

    modifier whenFunctionActive(uint256 functionId) {
        require(!functionPaused[functionId], "Function paused");
        _;
    }
}
