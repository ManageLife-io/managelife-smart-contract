// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../../libraries/StakingConstants.sol";

/// @title BaseRewards - Basic staking and reward distribution contract
/// @notice Implements a staking mechanism where users can stake tokens and earn rewards
/// @dev Inherits from Ownable for access control and ReentrancyGuard for security
contract BaseRewards is Ownable, ReentrancyGuard {
    // SafeMath no longer needed in Solidity 0.8.x
    uint256 public constant MIN_STAKING_PERIOD = StakingConstants.MIN_STAKING_PERIOD;
    
    // Decimal handling
    uint256 public immutable stakingTokenUnit;
    uint256 public immutable rewardsTokenUnit;
    
    ERC20 public immutable stakingToken;
    ERC20 public immutable rewardsToken;
    

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
    
    function setMinStakingPeriod(uint256 period) external onlyOwner {
        minStakingPeriod = period;
        emit MinStakingPeriodUpdated(period);
    }
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
            endTime: 0
        });
        rewardPeriods.push(newPeriod);
        
        lastUpdateTime = block.timestamp;
        lastRateChange = block.timestamp;
        emit RewardRateUpdated(oldRate, _rewardRate, msg.sender);
    }

    event CircuitBreakerToggled(bool paused);

    function toggleRateChangePaused(bool paused) external onlyOwner {
        rateChangePaused = paused;
        emit CircuitBreakerToggled(paused);
    }

    /// @notice Allows owner to rescue any ERC20 tokens sent to the contract
    /// @dev Only callable by contract owner
    /// @param tokenAddress Address of the token to rescue
    /// @param amount Amount of tokens to rescue
    function rescueERC20(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw staking token");
        require(tokenAddress != address(rewardsToken), "Cannot withdraw rewards token");
        require(IERC20(tokenAddress).transfer(owner(), amount), "Token rescue transfer failed");
        emit TokensRescued(tokenAddress, amount, owner());
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
