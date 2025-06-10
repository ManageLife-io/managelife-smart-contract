// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../../libraries/StakingConstants.sol";

contract DynamicRewards is AccessControl, ReentrancyGuard {
    bool private _paused;

    modifier whenNotPaused() {
        require(!_paused, "Contract is paused");
        _;
    }
    
    // ================== Constants ==================
    uint256 public constant TOKEN_UNIT = 1e18; // Precision unit for token calculations
    uint256 public constant MULTIPLIER = 1e18; // Multiplier for reward calculations
    uint256 public constant PERCENTAGE_BASE = 10000; // Base for percentage calculations (100% = 10000)
    uint256 public constant MAX_REWARD_MULTIPLIER = 10; // Maximum reward multiplier (10x)
    uint256 public constant PRECISION_FACTOR = 1e12; // High precision factor for calculations

    bytes32 public constant REWARD_MANAGER = keccak256("REWARD_MANAGER");
    
    struct RewardSchedule {
        uint256 startTime;
        uint256 endTime;
        uint256 totalRewards;
        uint256 claimedRewards;
        address rewardsToken; // Supports multiple reward tokens
    }

    // Historical stake tracking structures
    struct StakeSnapshot {
        uint256 balance;
        uint256 timestamp;
        uint256 totalSupplyAtTime;
    }

    IERC20 public immutable stakingToken;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _snapshotBalances;
    mapping(address => uint256) private _stakeTimestamps;
    
    // Enhanced staking tracking to prevent gaming
    struct StakeEntry {
        uint256 amount;
        uint256 timestamp;
    }
    mapping(address => StakeEntry[]) private _stakeEntries;

    // Historical tracking mappings
    mapping(address => StakeSnapshot[]) private _stakeHistory;
    mapping(address => uint256) private _lastSnapshotIndex;
    mapping(uint256 => uint256) private _totalSupplyHistory; // timestamp => total supply
    uint256[] private _totalSupplyTimestamps;

    uint256 public constant MIN_STAKING_PERIOD = StakingConstants.MIN_STAKING_PERIOD;
    uint256 public minStakingPeriod = MIN_STAKING_PERIOD;
    event MinStakingPeriodUpdated(uint256 newPeriod);

    mapping(uint256 => RewardSchedule) public rewardSchedules;
    uint256 public currentScheduleId;
    mapping(address => mapping(uint256 => uint256)) private _userAccrued;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardScheduleAdded(uint256 scheduleId);
    event RewardClaimed(address indexed user, uint256 amount, address token);
    event StakeSnapshotCreated(address indexed user, uint256 balance, uint256 timestamp);
    
    function setMinStakingPeriod(uint256 period) external onlyRole(REWARD_MANAGER) {
        minStakingPeriod = period;
        emit MinStakingPeriodUpdated(period);
    }

    constructor(address _stakingToken, address admin) {
        require(_stakingToken != address(0), "Invalid staking token");
        require(admin != address(0), "Invalid admin address");
        _paused = false;
        stakingToken = IERC20(_stakingToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REWARD_MANAGER, admin);
    }

    // ================== Historical Tracking Functions ==================
    function _createStakeSnapshot(address account) internal {
        uint256 currentBalance = _balances[account];
        uint256 currentTime = block.timestamp;
        
        _stakeHistory[account].push(StakeSnapshot({
            balance: currentBalance,
            timestamp: currentTime,
            totalSupplyAtTime: _totalSupply
        }));
        
        _lastSnapshotIndex[account] = _stakeHistory[account].length - 1;
        
        // Update total supply history
        _totalSupplyHistory[currentTime] = _totalSupply;
        _totalSupplyTimestamps.push(currentTime);
        
        emit StakeSnapshotCreated(account, currentBalance, currentTime);
    }

    function getStakeHistoryLength(address account) external view returns (uint256) {
        return _stakeHistory[account].length;
    }

    function getStakeSnapshotAt(address account, uint256 index) external view returns (StakeSnapshot memory) {
        require(index < _stakeHistory[account].length, "Index out of bounds");
        return _stakeHistory[account][index];
    }

    function getBalanceAtTime(address account, uint256 timestamp) public view returns (uint256) {
        StakeSnapshot[] storage history = _stakeHistory[account];
        if (history.length == 0) return 0;
        
        // Binary search for the closest snapshot before or at the timestamp
        uint256 left = 0;
        uint256 right = history.length - 1;
        
        while (left <= right) {
            uint256 mid = (left + right) / 2;
            if (history[mid].timestamp <= timestamp) {
                if (mid == history.length - 1 || history[mid + 1].timestamp > timestamp) {
                    return history[mid].balance;
                }
                left = mid + 1;
            } else {
                if (mid == 0) return 0;
                right = mid - 1;
            }
        }
        
        return 0;
    }

    function getTotalSupplyAtTime(uint256 timestamp) public view returns (uint256) {
        if (_totalSupplyTimestamps.length == 0) return 0;
        
        // Binary search for the closest total supply before or at the timestamp
        uint256 left = 0;
        uint256 right = _totalSupplyTimestamps.length - 1;
        
        while (left <= right) {
            uint256 mid = (left + right) / 2;
            uint256 midTimestamp = _totalSupplyTimestamps[mid];
            
            if (midTimestamp <= timestamp) {
                if (mid == _totalSupplyTimestamps.length - 1 || _totalSupplyTimestamps[mid + 1] > timestamp) {
                    return _totalSupplyHistory[midTimestamp];
                }
                left = mid + 1;
            } else {
                if (mid == 0) return 0;
                right = mid - 1;
            }
        }
        
        return 0;
    }

    // ================== Core Functions ==================
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        
        // Check if there are active reward schedules
        require(hasActiveRewardSchedules(), "No active reward schedules available");
        
        _updateRewards(msg.sender);
        
        _totalSupply = _totalSupply + amount;
        _balances[msg.sender] = _balances[msg.sender] + amount;
        
        // Update stake timestamp for each new stake to prevent gaming
        // This ensures users must wait the minimum period for each stake amount
        _stakeTimestamps[msg.sender] = block.timestamp;
        
        // Record individual stake entry for precise tracking
        _stakeEntries[msg.sender].push(StakeEntry({
            amount: amount,
            timestamp: block.timestamp
        }));
        
        // Create historical snapshot
        _createStakeSnapshot(msg.sender);
        
        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Cannot withdraw 0");
        
        uint256 withdrawableAmount = getWithdrawableAmount(msg.sender);
        require(withdrawableAmount >= amount, "Insufficient withdrawable balance");
        
        _updateRewards(msg.sender);
        
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
        _totalSupply = _totalSupply - amount;
        _balances[msg.sender] = _balances[msg.sender] - amount;
        
        // Create historical snapshot
        _createStakeSnapshot(msg.sender);
        
        bool success = stakingToken.transfer(msg.sender, amount);
        require(success, "Transfer failed");
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

    // ================== Reward Management ==================
    function addRewardSchedule(
        uint256 startTime,
        uint256 duration,
        uint256 totalReward,
        address rewardsToken
    ) external onlyRole(REWARD_MANAGER) {
        require(startTime >= block.timestamp, "Start time in past");
        require(duration > 0, "Invalid duration");
        require(totalReward > 0, "Invalid reward amount");
        
        uint256 balance = IERC20(rewardsToken).balanceOf(address(this));
        require(balance >= totalReward, "Insufficient reward tokens");

        uint256 scheduleId = ++currentScheduleId;
        rewardSchedules[scheduleId] = RewardSchedule({
            startTime: startTime,
            endTime: startTime + duration,
            totalRewards: totalReward,
            claimedRewards: 0,
            rewardsToken: rewardsToken
        });

        emit RewardScheduleAdded(scheduleId);
    }

    // ================== Reward Calculation ==================
    function earned(address account) public view returns (uint256 total) {
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            total = total + _earnedPerSchedule(account, i);
        }
    }

    function _earnedPerSchedule(address account, uint256 scheduleId) private view returns (uint256) {
        RewardSchedule storage schedule = rewardSchedules[scheduleId];
        if (block.timestamp < schedule.startTime) return 0;
    
        // Additional boundary check
        uint256 totalDuration = schedule.endTime - schedule.startTime;
        require(totalDuration > 0, "Invalid schedule duration");
        
        // Use historical balance at schedule start time for more accurate calculation
        uint256 userBalanceAtStart = getBalanceAtTime(account, schedule.startTime);
        uint256 totalSupplyAtStart = getTotalSupplyAtTime(schedule.startTime);
        
        if (userBalanceAtStart == 0 || totalSupplyAtStart == 0) return 0;
    
        // Check if schedule has ended
        if (block.timestamp >= schedule.endTime) {
            // For ended schedules, calculate based on full duration using historical data
            uint256 endedAvailableRewards = schedule.totalRewards;
            uint256 endedUserShare = userBalanceAtStart * endedAvailableRewards / totalSupplyAtStart;
            
            return endedUserShare > _userAccrued[account][scheduleId] ? 
                   endedUserShare - _userAccrued[account][scheduleId] : 0;
        }
        
        uint256 timeElapsed = block.timestamp - schedule.startTime;
        if (timeElapsed > totalDuration) { // Time upper limit check
            timeElapsed = totalDuration;
        }
    
        // Calculate rewards based on historical balance and total supply
        uint256 availableRewards = schedule.totalRewards * timeElapsed / totalDuration;
        uint256 userShare = userBalanceAtStart * availableRewards / totalSupplyAtStart;
        
        return userShare > _userAccrued[account][scheduleId] ? 
               userShare - _userAccrued[account][scheduleId] : 0;
    }

    // ================== Reward Claiming ==================
    function claimRewards() external nonReentrant whenNotPaused {
        _updateRewards(msg.sender);
        
        uint256 totalClaimed = 0;
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            RewardSchedule storage schedule = rewardSchedules[i];
            uint256 amount = _userAccrued[msg.sender][i];
            if (amount == 0) continue;

            // Enhanced security checks
            require(amount > 0, "Nothing to claim");
            
            // Check if claiming would exceed total rewards for this schedule
            require(
                schedule.claimedRewards + amount <= schedule.totalRewards,
                "Claim exceeds total rewards"
            );
            
            // Check contract has sufficient balance for this specific token
            require(
                IERC20(schedule.rewardsToken).balanceOf(address(this)) >= amount,
                "Insufficient contract balance"
            );
            
            // Reset user accrued before transfer to prevent reentrancy
            _userAccrued[msg.sender][i] = 0;
            schedule.claimedRewards = schedule.claimedRewards + amount;
            
            _sendReward(schedule.rewardsToken, msg.sender, amount);
            totalClaimed = totalClaimed + amount;
            
            // Emit individual claim event for better tracking
            emit RewardClaimed(msg.sender, amount, schedule.rewardsToken);
        }

        require(totalClaimed > 0, "No rewards");
    }

    // ================== Internal Functions ==================
    function _updateRewards(address account) internal {
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            // Calculate earned amount for this schedule
            uint256 earnedAmount = _earnedPerSchedule(account, i);
            
            // Only update if there are new rewards to add
            if (earnedAmount > 0) {
                // Ensure we don't exceed the maximum possible rewards for this user
                RewardSchedule storage schedule = rewardSchedules[i];
                uint256 userBalanceAtStart = getBalanceAtTime(account, schedule.startTime);
                uint256 totalSupplyAtStart = getTotalSupplyAtTime(schedule.startTime);
                
                if (userBalanceAtStart > 0 && totalSupplyAtStart > 0) {
                    // Calculate maximum possible rewards for this user in this schedule
                    uint256 maxUserRewards = userBalanceAtStart * schedule.totalRewards / totalSupplyAtStart;
                    
                    // Ensure total accrued doesn't exceed maximum
                    uint256 newAccrued = _userAccrued[account][i] + earnedAmount;
                    if (newAccrued > maxUserRewards) {
                        earnedAmount = maxUserRewards > _userAccrued[account][i] ? 
                                     maxUserRewards - _userAccrued[account][i] : 0;
                    }
                    
                    if (earnedAmount > 0) {
                        _userAccrued[account][i] = _userAccrued[account][i] + earnedAmount;
                    }
                }
            }
        }
    }

    function _sendReward(address token, address to, uint256 amount) internal {
        require(
            IERC20(token).balanceOf(address(this)) >= amount,
            "Insufficient reward balance"
        );
        bool success = IERC20(token).transfer(to, amount);
        require(success, "Transfer failed");
    }

    // ================== Pause Functions ==================
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _paused = true;
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _paused = false;
    }

    // ================== View Functions ==================
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function totalStaked() external view returns (uint256) {
        return _totalSupply;
    }

    function getActiveSchedules() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            if (block.timestamp < rewardSchedules[i].endTime) {
                count++;
            }
        }

        uint256[] memory active = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            if (block.timestamp < rewardSchedules[i].endTime) {
                active[index++] = i;
            }
        }
        return active;
    }

    /// @notice Check if there are any active reward schedules
    /// @return true if there are active reward schedules, false otherwise
    function hasActiveRewardSchedules() public view returns (bool) {
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            if (block.timestamp < rewardSchedules[i].endTime) {
                return true;
            }
        }
        return false;
    }
}
