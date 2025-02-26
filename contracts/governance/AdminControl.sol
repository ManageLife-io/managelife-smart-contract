// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract AdminControl is AccessControl, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    // ========== 角色权限定义 ==========
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant LEGAL_ROLE = keccak256("LEGAL_ROLE");
    bytes32 public constant REWARD_MANAGER = keccak256("REWARD_MANAGER");

    // ========== 手续费结构 ==========
    struct FeeSettings {
        uint256 baseFee;        // 基础交易费率（基点：100 = 1%）
        uint256 maxFee;         // 最大允许费率（基点）
        address feeCollector;   // 手续费接收地址
    }

    // ========== 奖励参数结构 ==========
    struct RewardParameters {
        uint256 baseRate;              // 基础奖励率（基点）
        uint256 communityMultiplier;   // 社区加成系数
        uint256 maxLeaseBonus;         // 最大租赁期限加成
        address rewardsVault;          // 奖励金库地址
    }

    // ========== 状态变量 ==========
    FeeSettings public feeConfig;
    RewardParameters public rewardParams;
    
    EnumerableSet.AddressSet private _kycVerified;
    mapping(address => uint256) public communityScores;
    mapping(uint256 => bool) public functionPaused;

    // ========== 事件定义 ==========
    event FeeConfigUpdated(uint256 newBaseFee, uint256 newMaxFee);
    event RewardParametersUpdated(uint256 newBaseRate, uint256 newMultiplier);
    event KYCStatusUpdated(address indexed account, bool status);
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
        require(initialAdmin != address(0), "Invalid admin address");
        
        // 初始化角色分配
        _initializeRoles(initialAdmin);

        // 初始化费用配置
        feeConfig = FeeSettings({
            baseFee: 200,       // 2%
            maxFee: 1000,       // 10%
            feeCollector: feeCollector
        });

        // 初始化奖励参数
        rewardParams = RewardParameters({
            baseRate: 1000,     // 10% 基础奖励
            communityMultiplier: 2000, // 20% 社区最大加成
            maxLeaseBonus: 300, // 3% 最大租赁加成
            rewardsVault: rewardsVault
        });
    }

    // ========== 手续费管理 ==========
    function updateFeeConfig(
        uint256 newBaseFee, 
        address newCollector
    ) external onlyRole(OPERATOR_ROLE) {
        require(newBaseFee <= feeConfig.maxFee, "Exceeds max fee");
        feeConfig.baseFee = newBaseFee;
        feeConfig.feeCollector = newCollector;
        emit FeeConfigUpdated(newBaseFee, feeConfig.maxFee);
    }

    // ========== KYC 管理 ==========
    function batchApproveKYC(
        address[] calldata accounts, 
        bool approved
    ) external onlyRole(LEGAL_ROLE) {
        for(uint i = 0; i < accounts.length; i++) {
            approved ? _kycVerified.add(accounts[i]) : _kycVerified.remove(accounts[i]);
            emit KYCStatusUpdated(accounts[i], approved);
        }
    }

    // ========== 奖励管理 ==========
    function configureRewards(
        uint256 newBaseRate,
        uint256 newMultiplier,
        uint256 newLeaseBonus
    ) external onlyRole(REWARD_MANAGER) {
        require(newBaseRate <= 2000, "Base rate >20%");
        require(newMultiplier <= 1500, "Multiplier >15%");
        require(newLeaseBonus <= 500, "Lease bonus >5%");

        rewardParams.baseRate = newBaseRate;
        rewardParams.communityMultiplier = newMultiplier;
        rewardParams.maxLeaseBonus = newLeaseBonus;
        
        emit RewardParametersUpdated(newBaseRate, newMultiplier);
    }

    // ========== 紧急控制 ==========
    function emergencyPauseFunction(
        uint256 functionId, 
        bool paused
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        functionPaused[functionId] = paused;
    }

    function globalPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function globalUnpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ========== 社区积分管理 ==========
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

    // ========== 视图函数 ==========
    function getCurrentFee() external view returns (uint256) {
        return feeConfig.baseFee;
    }

    function isKYCVerified(address account) external view returns (bool) {
        return _kycVerified.contains(account);
    }

    function calculateRewards(
        address user, 
        uint256 baseAmount
    ) external view returns (uint256) {
        uint256 leaseBonus = _getLeaseBonus(user);
        uint256 communityBonus = _getCommunityBonus(user);
        return baseAmount * (rewardParams.baseRate + leaseBonus + communityBonus) / 10000;
    }

    // ========== 内部函数 ==========
    function _getLeaseBonus(address /*user*/) internal view returns (uint256) {
        // 根据实际租赁数据计算加成
         return rewardParams.maxLeaseBonus;  // 暂时返回配置的最大值
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
