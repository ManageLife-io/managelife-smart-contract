// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../../libraries/StakingConstants.sol";

contract BaseRewards is Ownable, ReentrancyGuard {
    uint256 public constant MIN_STAKING_PERIOD = StakingConstants.MIN_STAKING_PERIOD;
    
    uint256 public immutable stakingTokenUnit;
    uint256 public immutable rewardsTokenUnit;
    
    ERC20 public immutable stakingToken;
    ERC20 public immutable rewardsToken;
    
    struct RewardPeriod {
        uint256 rate;
        uint256 startTime;
        uint256 endTime;
    }
    
    RewardPeriod[] public rewardPeriods;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public rewardExpirationTimestamps;
    uint256 public constant MAX_CLAIM_PERIOD_DAYS = 30;
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant MAX_CLAIM_PERIOD = MAX_CLAIM_PERIOD_DAYS * SECONDS_PER_DAY;
    uint256 public constant MAX_REWARD_RATE = 1e20;
    uint256 public constant MAX_PERIODS_PROCESSED = 100;
    uint256 public constant TOKEN_PRECISION = 1e18;
    uint256 public constant PERCENTAGE_BASE = 10000;
    uint256 public constant RATE_CHANGE_COOLDOWN = 1 days;
    uint256 public lastRateChange;
    bool public rateChangePaused;
    event RewardExpired(address indexed user, uint256 amount);

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _stakeTimestamps;
    mapping(address => uint256) private _snapshotBalances;
    uint256 public minStakingPeriod = MIN_STAKING_PERIOD;
    
    struct StakeEntry {
        uint256 amount;
        uint256 timestamp;
    }
    mapping(address => StakeEntry[]) private _stakeEntries;
    mapping(address => uint256) private _totalWithdrawable;
    event MinStakingPeriodUpdated(uint256 newPeriod);

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate, address indexed admin);
    event TokensRescued(address indexed token, uint256 amount, address indexed recipient);
    event CircuitBreakerToggled(bool paused, address indexed admin);
    
    function setMinStakingPeriod(uint256 period) external onlyOwner {
        minStakingPeriod = period;
        emit MinStakingPeriodUpdated(period);
    }

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

    // Security: Disable dangerous renouncement function
    function renounceOwnership() public view override onlyOwner {
        revert("Ownership renunciation disabled");
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
        
        // Update stake timestamp for each new stake to prevent gaming
        // This ensures users must wait the minimum period for each stake amount
        _stakeTimestamps[msg.sender] = block.timestamp;
        
        // Record individual stake entry for precise tracking
        _stakeEntries[msg.sender].push(StakeEntry({
            amount: amountReceived,
            timestamp: block.timestamp
        }));
        
        emit Staked(msg.sender, amountReceived);
    }

    /// @notice Allows users to withdraw their staked tokens using FIFO logic
    /// @dev Updates rewards before processing withdrawal, enforces minimum staking period per stake
    /// @param amount Amount of tokens to withdraw
    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        
        uint256 withdrawableAmount = getWithdrawableAmount(msg.sender);
        require(withdrawableAmount >= amount, "Insufficient withdrawable balance");
        
        // Process withdrawal using FIFO logic
        uint256 remainingToWithdraw = amount;
        StakeEntry[] storage userStakes = _stakeEntries[msg.sender];
        
        for (uint256 i = 0; i < userStakes.length && remainingToWithdraw > 0; i++) {
            StakeEntry storage entry = userStakes[i];
            
            // Skip if this stake hasn't met minimum period
            if (block.timestamp < entry.timestamp + minStakingPeriod) {
                continue;
            }
            
            // Skip if this entry is already fully withdrawn
            if (entry.amount == 0) {
                continue;
            }
            
            uint256 withdrawFromEntry = remainingToWithdraw > entry.amount ? entry.amount : remainingToWithdraw;
            entry.amount -= withdrawFromEntry;
            remainingToWithdraw -= withdrawFromEntry;
        }
        
        require(remainingToWithdraw == 0, "Withdrawal calculation error");
        
        // Update balances
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
        
        // Transfer tokens
        require(stakingToken.transfer(msg.sender, amount), "Token transfer failed");
        emit Withdrawn(msg.sender, amount);
    }
    
    /// @notice Calculates the amount a user can withdraw (stakes that have met minimum period)
    /// @param account User address to check
    /// @return Total withdrawable amount
    function getWithdrawableAmount(address account) public view returns (uint256) {
        uint256 withdrawable = 0;
        StakeEntry[] storage userStakes = _stakeEntries[account];
        
        for (uint256 i = 0; i < userStakes.length; i++) {
            StakeEntry storage entry = userStakes[i];
            
            // Only count stakes that have met the minimum period
            if (block.timestamp >= entry.timestamp + minStakingPeriod) {
                withdrawable += entry.amount;
            }
        }
        
        return withdrawable;
    }

    /// @notice Allows users to claim their accumulated rewards
    /// @dev Updates rewards before processing claim
    function claimReward() external nonReentrant updateReward(msg.sender) {
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
        require(account != address(0), "Invalid account address");
        require(rewardExpirationTimestamps[account] > 0, "No rewards to clear");
        require(block.timestamp > rewardExpirationTimestamps[account], "Rewards not expired");
        
        uint256 expiredAmount = rewards[account];
        rewards[account] = 0;
        rewardExpirationTimestamps[account] = 0;
        
        emit RewardExpired(account, expiredAmount);
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
            lastPeriod.endTime = block.timestamp;
        }
        RewardPeriod memory newPeriod = RewardPeriod({
            rate: _rewardRate,
            startTime: block.timestamp,
            endTime: type(uint256).max  // Set to max value to indicate indefinite period
        });
        rewardPeriods.push(newPeriod);
        
        lastUpdateTime = block.timestamp;
        lastRateChange = block.timestamp;
        emit RewardRateUpdated(oldRate, _rewardRate, msg.sender);
    }

    function toggleRateChangePaused(bool paused) external onlyOwner {
        rateChangePaused = paused;
        emit CircuitBreakerToggled(paused, msg.sender);
    }
    
    // Emergency state variables
    bool public emergencyMode = false;
    event EmergencyModeActivated(address indexed activator, uint256 timestamp);
    event EmergencyWithdrawal(address indexed user, uint256 amount);
    
    /// @notice Activates emergency mode allowing users to withdraw their staked tokens regardless of staking period
    /// @dev Can only be called by the contract owner in case of emergency
    function activateEmergencyMode() external onlyOwner {
        require(!emergencyMode, "Emergency mode already active");
        emergencyMode = true;
        emit EmergencyModeActivated(msg.sender, block.timestamp);
    }
    
    /// @notice Allows users to withdraw their staked tokens in emergency mode
    /// @dev Bypasses minimum staking period check but still updates rewards
    function emergencyWithdraw() external nonReentrant updateReward(msg.sender) {
        require(emergencyMode, "Emergency mode not active");
        
        uint256 amount = _balances[msg.sender];
        require(amount > 0, "No staked tokens to withdraw");
        
        // Update state before transfer
        _balances[msg.sender] = 0;
        _totalSupply = _totalSupply - amount;
        
        // Transfer tokens to user
        require(stakingToken.transfer(msg.sender, amount), "Emergency token transfer failed");
        
        emit EmergencyWithdrawal(msg.sender, amount);
    }

    /// @notice Allows owner to rescue any ERC20 tokens sent to the contract
    /// @dev Only callable by contract owner, with strict restrictions on staking and reward tokens
    /// @param tokenAddress Address of the token to rescue
    /// @param amount Amount of tokens to rescue
    function rescueERC20(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(0), "Invalid token address");
        require(amount > 0, "Cannot rescue zero amount");
        
        // Completely prohibit withdrawal of staking tokens
        require(tokenAddress != address(stakingToken), "Cannot withdraw staking token");
        
        // For reward tokens, only allow rescue of excess tokens beyond what's needed for rewards
        if (tokenAddress == address(rewardsToken)) {
            uint256 contractBalance = rewardsToken.balanceOf(address(this));
            uint256 totalPendingRewards = calculateTotalPendingRewards();
            uint256 availableForRescue = contractBalance > totalPendingRewards ? contractBalance - totalPendingRewards : 0;
            
            require(availableForRescue > 0, "No excess reward tokens available for rescue");
            require(amount <= availableForRescue, "Amount exceeds available excess reward tokens");
        }
        
        require(IERC20(tokenAddress).transfer(owner(), amount), "Token rescue transfer failed");
        emit TokensRescued(tokenAddress, amount, owner());
    }
    
    /// @notice Calculates total pending rewards for all users
    /// @dev Internal function to determine how many reward tokens are committed to users
    /// @return Total amount of pending rewards
    function calculateTotalPendingRewards() internal view returns (uint256) {
        // This is a simplified calculation - in a production environment,
        // you might need to iterate through all users or maintain a running total
        // For now, we'll use a conservative approach and assume all rewards are pending
        uint256 totalRewards = 0;
        
        // Calculate rewards based on current state
        // This is a conservative estimate to prevent unauthorized withdrawals
        if (_totalSupply > 0 && rewardPeriods.length > 0) {
            // Estimate total rewards that could be claimed
            // This is intentionally conservative to protect user funds
            uint256 currentRewardPerToken = rewardPerToken();
            totalRewards = (_totalSupply * currentRewardPerToken) / stakingTokenUnit;
        }
        
        return totalRewards;
    }

    /******************** View Functions ********************/
    /// @notice Returns the total amount of tokens staked in the contract
    /// @return Total supply of staked tokens
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Returns the staked balance of a specific account
    /// @param account Address of the account to check
    /// @return Balance of staked tokens
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
                // Handle indefinite periods (endTime = type(uint256).max)
                uint256 periodEnd = (periodEndTime == type(uint256).max || periodEndTime > block.timestamp) ? block.timestamp : periodEndTime;
                
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

    /******************** Modifiers ********************/
    modifier updateReward(address account) {
        // Store current reward per token value
        uint256 currentRewardPerToken = rewardPerToken();
        
        // Update stored values
        rewardPerTokenStored = currentRewardPerToken;
        lastUpdateTime = block.timestamp;
        
        // Update account-specific reward data if account is valid
        if (account != address(0)) {
            // Calculate and store earned rewards using current snapshot balance
            rewards[account] = earned(account);
            // Update user's paid reward per token to current value
            userRewardPerTokenPaid[account] = currentRewardPerToken;
            rewardExpirationTimestamps[account] = block.timestamp + MAX_CLAIM_PERIOD;
        }
        _;
        // Update snapshot balance AFTER the function execution to capture new balance
        if (account != address(0)) {
            _snapshotBalances[account] = _balances[account];
        }
    }
}
