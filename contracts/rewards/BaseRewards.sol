// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../../libraries/StakingConstants.sol";

// Admin control interface
interface IAdminControl {
    function getCommunityScore(address user) external view returns (uint256);
}

/// @title BaseRewards - Basic staking and reward distribution contract
/// @notice Implements a staking mechanism where users can stake tokens and earn rewards
/// @dev Inherits from Ownable for access control and ReentrancyGuard for security
contract BaseRewards is Ownable, ReentrancyGuard {
    // SafeMath no longer needed in Solidity 0.8.x
    uint256 public constant MIN_STAKING_PERIOD = StakingConstants.MIN_STAKING_PERIOD;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_STAKING_DAYS = 3650; // 10 years
    uint256 public constant MAX_REWARD_AMOUNT = 1e30; // Maximum reward cap
    
    // Decimal handling
    uint256 public immutable stakingTokenUnit;
    uint256 public immutable rewardsTokenUnit;
    
    ERC20 public immutable stakingToken;
    ERC20 public immutable rewardsToken;
    
    IAdminControl public adminControl;
    
    // Reward configuration
    struct RewardConfig {
        uint256 baseRewardRate;
        uint256 communityBonusRate;
        uint256 leaseBonusRate;
    }
    
    RewardConfig public rewardConfig;

    // Reward rate parameters
    struct RewardPeriod {
        uint256 rate;
        uint256 startTime;
        uint256 endTime;
    }
    
    RewardPeriod[] public rewardPeriods;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    // User configurations
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public rewardExpirationTimestamps;
    uint256 public constant MAX_CLAIM_PERIOD = 30 days;
    uint256 public constant MAX_REWARD_RATE = 1e20; // 100 tokens per second per staked token
    uint256 public constant MAX_PERIODS_PROCESSED = 100; // Maximum periods processed per call
    uint256 public constant RATE_CHANGE_COOLDOWN = 1 days;
    uint256 public lastRateChange;
    bool public rateChangePaused;
    event RewardExpired(address indexed user, uint256 amount);

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _stakeTimestamps;
    mapping(address => uint256) private _snapshotBalances;
    uint256 public minStakingPeriod = MIN_STAKING_PERIOD;
    event MinStakingPeriodUpdated(uint256 newPeriod);

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate, address indexed admin);
    event TokensRescued(address indexed token, uint256 amount, address indexed admin);

    constructor(
        address _stakingToken,
        address _rewardsToken,
        address initialOwner
    ) Ownable() {
        require(_stakingToken != address(0), "Invalid staking token address");
        require(_rewardsToken != address(0), "Invalid rewards token address");
        
        stakingToken = ERC20(_stakingToken);
        rewardsToken = ERC20(_rewardsToken);
    
        // Initialize immutable variables directly in constructor without using try/catch
        uint256 _stakingTokenUnit;
        uint256 _rewardsTokenUnit;
        
        // Get token decimals using temporary variables
        try stakingToken.decimals() returns (uint8 decimals) {
            _stakingTokenUnit = 10 ** uint256(decimals);
        } catch {
            _stakingTokenUnit = 1e18;
        }
        
        try rewardsToken.decimals() returns (uint8 decimals) {
            _rewardsTokenUnit = 10 ** uint256(decimals);
        } catch {
            _rewardsTokenUnit = 1e18;
        }
        
        // Initialize immutable variables using temporary values
        stakingTokenUnit = _stakingTokenUnit;
        rewardsTokenUnit = _rewardsTokenUnit;
        
        // Transfer ownership
        if (initialOwner != address(0) && initialOwner != msg.sender) {
            _transferOwnership(initialOwner);
        }
    }

    /******************** Core Functions ********************/
    /// @notice Allows users to stake tokens
    /// @dev Updates rewards before processing stake
    /// @param amount Amount of tokens to stake
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        
        // Check if rewards pool has sufficient tokens
        require(rewardsToken.balanceOf(address(this)) > 0, "Rewards pool is empty");
        
        // Transfer tokens first to ensure the transaction succeeds before updating state
        uint256 balanceBefore = stakingToken.balanceOf(address(this));
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        uint256 balanceAfter = stakingToken.balanceOf(address(this));
        
        // Verify the actual amount received
        uint256 amountReceived = balanceAfter - balanceBefore;
        require(amountReceived == amount, "Incorrect amount received");
        
        // Update state variables
        _totalSupply = _totalSupply + amountReceived;
        _balances[msg.sender] = _balances[msg.sender] + amountReceived;
        _stakeTimestamps[msg.sender] = block.timestamp;
        
        emit Staked(msg.sender, amountReceived);
    }

    /// @notice Allows users to withdraw their staked tokens
    /// @dev Updates rewards before processing withdrawal
    /// @param amount Amount of tokens to withdraw
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(block.timestamp >= _stakeTimestamps[msg.sender] + minStakingPeriod, "Minimum staking period not met");
        require(amount > 0, "Cannot withdraw 0");
        // Explicit balance check using SafeMath
        uint256 currentBalance = _balances[msg.sender];
        require(currentBalance >= amount, "Insufficient staked balance");
        
        // Native subtraction with automatic underflow protection in Solidity 0.8.20
        _balances[msg.sender] = currentBalance - amount;
        _totalSupply = _totalSupply - amount;
        
        // Maintain checks-effects-interactions pattern
        require(stakingToken.transfer(msg.sender, amount), "Token transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Allows users to claim their accumulated rewards
    /// @dev Updates rewards before processing claim
    function claimReward() public nonReentrant updateReward(msg.sender) {
        require(block.timestamp <= rewardExpirationTimestamps[msg.sender], "Reward claim period expired");
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            require(rewardsToken.balanceOf(address(this)) >= reward, "Insufficient reward token balance");
            require(rewardsToken.transfer(msg.sender, reward), "Reward transfer failed");
            emit RewardPaid(msg.sender, reward);
        }
    }

    function clearExpiredRewards(address account) external nonReentrant {
        require(block.timestamp > rewardExpirationTimestamps[account], "Reward not expired");
        uint256 expiredAmount = rewards[account];
        rewards[account] = 0;
        emit RewardExpired(account, expiredAmount);
    }

    function setMinStakingPeriod(uint256 period) external onlyOwner {
        minStakingPeriod = period;
        emit MinStakingPeriodUpdated(period);
    }

    /******************** Management Functions ********************/
    /// @notice Sets the reward rate for the staking contract
    /// @dev Only callable by contract owner
    /// @param _rewardRate New reward rate per second
    function setRewardRate(uint256 _rewardRate) external onlyOwner updateReward(address(0)) {
        require(!rateChangePaused, "Circuit breaker active: rate changes paused");
        require(_rewardRate <= MAX_REWARD_RATE, "Reward rate exceeds maximum");
        require(block.timestamp >= lastRateChange + RATE_CHANGE_COOLDOWN, "Rate change cooldown active");
        
        uint256 oldRate = rewardPeriods.length > 0 ? rewardPeriods[rewardPeriods.length - 1].rate : 0;
        
        if (rewardPeriods.length > 0) {
            RewardPeriod storage lastPeriod = rewardPeriods[rewardPeriods.length - 1];
            if (lastPeriod.endTime > block.timestamp) {
                lastPeriod.endTime = block.timestamp;
            }
        }
        
        rewardPeriods.push(RewardPeriod({
            rate: _rewardRate,
            startTime: block.timestamp,
            endTime: type(uint256).max
        }));
        
        lastRateChange = block.timestamp;
        emit RewardRateUpdated(oldRate, _rewardRate, msg.sender);
    }

    function pauseRateChanges() external onlyOwner {
        rateChangePaused = true;
    }

    function unpauseRateChanges() external onlyOwner {
        rateChangePaused = false;
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(stakingToken), "Cannot rescue staking token");
        require(ERC20(token).transfer(msg.sender, amount), "Token transfer failed");
        emit TokensRescued(token, amount, msg.sender);
    }

    /******************** View Functions ********************/
    /// @notice Returns the total amount of tokens staked
    /// @return Total staked token amount
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Returns the amount of tokens staked by a specific account
    /// @param account Address to check
    /// @return Staked token amount for the account
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Calculates the current reward amount earned by an account
    /// @param account Address of the account to check
    /// @return Amount of rewards earned
    function earned(address account) public view returns (uint256) {
        return
            _snapshotBalances[account]
                * (rewardPerToken() - userRewardPerTokenPaid[account])
                / stakingTokenUnit
                 + rewards[account];
    }

    /// @notice Calculates the current reward per token stored
    /// @dev Used for reward distribution calculations
    /// @return Current reward per token rate
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0 || lastUpdateTime == 0) {
            return rewardPerTokenStored;
        }
        
        uint256 totalAdditionalReward = 0;
        uint256 periodsLength = rewardPeriods.length;
        uint256 processedPeriods = 0;
        for (uint256 i = 0; i < periodsLength; i++) {
            RewardPeriod memory period = rewardPeriods[i];
            uint256 periodEndTime = period.endTime;
            uint256 periodStartTime = period.startTime;
            
            if (periodEndTime > lastUpdateTime) {
                uint256 periodStart = periodStartTime > lastUpdateTime ? periodStartTime : lastUpdateTime;
                uint256 periodEnd = periodEndTime < block.timestamp ? periodEndTime : block.timestamp;
                
                if (periodEnd > periodStart) {
                    uint256 periodDuration = periodEnd - periodStart;
                    uint256 periodRate = period.rate;
                    
                    totalAdditionalReward = totalAdditionalReward + (
                        periodRate * periodDuration * rewardsTokenUnit / _totalSupply
                    );
                    
                    if (++processedPeriods >= MAX_PERIODS_PROCESSED) {
                        break;
                    }
                }
            }
        }
        return rewardPerTokenStored + totalAdditionalReward;
    }

    /// @notice Calculates rewards for a user based on their staking and community participation
    /// @dev Uses safe math operations to prevent overflow and optimized calculations
    /// @param user The address of the user
    /// @param stakingAmount The amount of tokens staked by the user
    /// @param stakingDuration The duration of staking in seconds
    /// @return totalReward The total calculated reward amount
    function calculateRewards(
        address user,
        uint256 stakingAmount,
        uint256 stakingDuration
    ) external view returns (uint256 totalReward) {
        require(user != address(0), "Invalid user address");
        require(stakingAmount > 0, "Invalid staking amount");
        require(stakingDuration > 0, "Invalid staking duration");
        
        // Get base reward rate with overflow protection
        uint256 baseRate = rewardConfig.baseRewardRate;
        require(baseRate > 0, "Base reward rate not set");
        
        // Calculate base reward with overflow checks
        // Use intermediate calculations to prevent overflow
        uint256 timeMultiplier = stakingDuration / 1 days; // Convert to days
        require(timeMultiplier <= MAX_STAKING_DAYS, "Staking duration too long");
        
        // Safe multiplication with overflow protection
        uint256 baseReward;
        unchecked {
            // Check for potential overflow before multiplication
            if (stakingAmount > type(uint256).max / baseRate) {
                revert("Calculation would overflow");
            }
            baseReward = stakingAmount * baseRate;
            
            if (baseReward > type(uint256).max / timeMultiplier) {
                revert("Calculation would overflow");
            }
            baseReward = (baseReward * timeMultiplier) / BASIS_POINTS;
        }
        
        // Get community bonus with safe calculations
        uint256 communityBonus = _calculateCommunityBonus(user, baseReward);
        
        // Get lease bonus with safe calculations
        uint256 leaseBonus = _calculateLeaseBonus(user, baseReward);
        
        // Safe addition with overflow check
        totalReward = baseReward;
        if (totalReward > type(uint256).max - communityBonus) {
            revert("Total reward calculation overflow");
        }
        totalReward += communityBonus;
        
        if (totalReward > type(uint256).max - leaseBonus) {
            revert("Total reward calculation overflow");
        }
        totalReward += leaseBonus;
        
        // Apply maximum reward cap
        if (totalReward > MAX_REWARD_AMOUNT) {
            totalReward = MAX_REWARD_AMOUNT;
        }
        
        return totalReward;
    }
    
    /// @notice Calculates community participation bonus
    /// @dev Internal function with optimized calculations
    /// @param user The user address
    /// @param baseReward The base reward amount
    /// @return bonus The calculated community bonus
    function _calculateCommunityBonus(address user, uint256 baseReward) internal view returns (uint256 bonus) {
        uint256 communityScore = adminControl.getCommunityScore(user);
        if (communityScore == 0) {
            return 0;
        }
        
        uint256 bonusRate = rewardConfig.communityBonusRate;
        if (bonusRate == 0) {
            return 0;
        }
        
        // Safe calculation with overflow protection
        unchecked {
            if (baseReward > type(uint256).max / bonusRate) {
                return MAX_REWARD_AMOUNT; // Cap at maximum
            }
            bonus = (baseReward * bonusRate * communityScore) / (BASIS_POINTS * 100);
        }
        
        return bonus;
    }
    
    /// @notice Calculates lease participation bonus
    /// @dev Internal function with optimized calculations
    /// @param user The user address
    /// @param baseReward The base reward amount
    /// @return bonus The calculated lease bonus
    function _calculateLeaseBonus(address user, uint256 baseReward) internal view returns (uint256 bonus) {
        // Check if user has active leases (simplified check)
        bool hasActiveLeases = _hasActiveLeases(user);
        if (!hasActiveLeases) {
            return 0;
        }
        
        uint256 bonusRate = rewardConfig.leaseBonusRate;
        if (bonusRate == 0) {
            return 0;
        }
        
        // Safe calculation with overflow protection
        unchecked {
            if (baseReward > type(uint256).max / bonusRate) {
                return MAX_REWARD_AMOUNT; // Cap at maximum
            }
            bonus = (baseReward * bonusRate) / BASIS_POINTS;
        }
        
        return bonus;
    }
    
    /// @notice Checks if user has active leases
    /// @dev Internal helper function
    /// @param user The user address
    /// @return hasLeases True if user has active leases
    function _hasActiveLeases(address user) internal view returns (bool hasLeases) {
        // This is a simplified implementation
        // In a real scenario, this would check against a lease registry
        return user != address(0); // Placeholder logic
    }

    /******************** Modifiers ********************/
    modifier updateReward(address account) {
        // Store current reward per token value
        uint256 currentRewardPerToken = rewardPerToken();
        
        // Update stored values
        rewardPerTokenStored = currentRewardPerToken;
        lastUpdateTime = block.timestamp;
        
        // Update account-specific reward data if account is valid
        if (account != address(0)) {
            // Calculate and store earned rewards
            rewards[account] = earned(account);
            // Update user's paid reward per token to current value
            userRewardPerTokenPaid[account] = currentRewardPerToken;
            _snapshotBalances[account] = _balances[account];
            rewardExpirationTimestamps[account] = block.timestamp + MAX_CLAIM_PERIOD;
        }
        _;
    }
}