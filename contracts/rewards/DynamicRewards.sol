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

    bytes32 public constant REWARD_MANAGER = keccak256("REWARD_MANAGER");
    
    struct RewardSchedule {
        uint256 startTime;
        uint256 endTime;
        uint256 totalRewards;
        uint256 claimedRewards;
        address rewardsToken; // Supports multiple reward tokens
    }

    IERC20 public immutable stakingToken;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _snapshotBalances;
    mapping(address => uint256) private _stakeTimestamps;

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

    // ================== Core Functions ==================
    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Amount must be > 0");
        _updateRewards(msg.sender);
        
        _totalSupply = _totalSupply + amount;
        _balances[msg.sender] = _balances[msg.sender] + amount;
        _stakeTimestamps[msg.sender] = block.timestamp;
        
        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(block.timestamp >= _stakeTimestamps[msg.sender] + minStakingPeriod, "Minimum staking period not met");
        require(amount > 0, "Amount must be > 0");
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        
        _updateRewards(msg.sender);
        _totalSupply = _totalSupply - amount;
        _snapshotBalances[msg.sender] = _balances[msg.sender];
        _balances[msg.sender] = _balances[msg.sender] - amount;
        
        bool success = stakingToken.transfer(msg.sender, amount);
        require(success, "Transfer failed");
        emit Withdrawn(msg.sender, amount);
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
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRewardPerTokenPaid;

    modifier updateReward(address account) {
        uint256 currentRewardPerToken = rewardPerToken();
        rewardPerTokenStored = currentRewardPerToken;
        lastUpdateTime = block.timestamp;
        
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = currentRewardPerToken;
            _snapshotBalances[account] = _balances[account];
        }
        _;
    }

    function earned(address account) public view returns (uint256 total) {
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            total = total + _earnedPerSchedule(account, i);
        }
    }

    function _earnedPerSchedule(address account, uint256 scheduleId) private view returns (uint256) {
        RewardSchedule storage schedule = rewardSchedules[scheduleId];
        if (_snapshotBalances[account] == 0 || block.timestamp < schedule.startTime) return 0;
    
        // Additional boundary check
        uint256 totalDuration = schedule.endTime - schedule.startTime;
        require(totalDuration > 0, "Invalid schedule duration");
        
        uint256 timeElapsed = block.timestamp - schedule.startTime;
        if (timeElapsed > totalDuration) { // Time upper limit check
            timeElapsed = totalDuration;
        }
    
        // Enhanced precision calculations to prevent precision loss
        // Use higher precision intermediate calculations
        uint256 PRECISION_MULTIPLIER = 1e18;

        // Calculate multiplier with higher precision
        uint256 multiplier = (timeElapsed * MULTIPLIER * PRECISION_MULTIPLIER) / totalDuration;

        // Calculate available rewards with higher precision
        uint256 availableRewards = (schedule.totalRewards * timeElapsed * PRECISION_MULTIPLIER) / totalDuration;

        // Calculate user share with higher precision
        uint256 userShare = (_balances[account] * multiplier) / (_totalSupply * PRECISION_MULTIPLIER);

        // Final calculation with precision adjustment
        uint256 earned = (availableRewards * userShare) / (TOKEN_UNIT * PRECISION_MULTIPLIER);

        // Ensure we don't underflow
        uint256 alreadyAccrued = _userAccrued[account][scheduleId];
        return earned > alreadyAccrued ? earned - alreadyAccrued : 0;
    }

    // ================== Reward Claiming ==================
    function claimRewards() external nonReentrant whenNotPaused {
        _updateRewards(msg.sender);
        
        uint256 totalClaimed = 0;
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            RewardSchedule storage schedule = rewardSchedules[i];
            uint256 amount = _userAccrued[msg.sender][i];
            if (amount == 0) continue;

            // Security checks
            require(amount > 0, "Nothing to claim");
            _userAccrued[msg.sender][i] = 0;
            schedule.claimedRewards = schedule.claimedRewards + amount;
            
            _sendReward(schedule.rewardsToken, msg.sender, amount);
            totalClaimed = totalClaimed + amount;
        }

        require(totalClaimed > 0, "No rewards");
        emit RewardClaimed(msg.sender, totalClaimed, address(stakingToken));
    }

    // ================== Internal Functions ==================
    function _updateRewards(address account) internal {
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            // Only update rewards if the schedule is still active
            if (block.timestamp < rewardSchedules[i].endTime) {
                _userAccrued[account][i] = _userAccrued[account][i] + _earnedPerSchedule(account, i);
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
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function totalStaked() public view returns (uint256) {
        return _totalSupply;
    }

    function getActiveSchedules() public view returns (uint256[] memory) {
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

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + ((block.timestamp - lastUpdateTime) * MULTIPLIER * rewardPerTokenStored) / _totalSupply;
    }
}
