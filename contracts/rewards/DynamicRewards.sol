// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract DynamicRewards is AccessControl, ReentrancyGuard {
    using SafeMath for uint256;

    bytes32 public constant REWARD_MANAGER = keccak256("REWARD_MANAGER");
    
    struct RewardSchedule {
        uint256 startTime;
        uint256 endTime;
        uint256 totalRewards;
        uint256 claimedRewards;
        address rewardsToken; // 支持多奖励代币
    }

    IERC20 public immutable stakingToken;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    mapping(uint256 => RewardSchedule) public rewardSchedules;
    uint256 public currentScheduleId;
    mapping(address => mapping(uint256 => uint256)) private _userAccrued;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardScheduleAdded(uint256 scheduleId);
    event RewardClaimed(address indexed user, uint256 amount, address token);

    constructor(address _stakingToken, address admin) {
        require(_stakingToken != address(0), "Invalid staking token");
        stakingToken = IERC20(_stakingToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REWARD_MANAGER, admin);
    }

    // ================== 核心功能 ==================
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        _updateRewards(msg.sender);
        
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        
        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        
        _updateRewards(msg.sender);
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        
        bool success = stakingToken.transfer(msg.sender, amount);
        require(success, "Transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    // ================== 奖励管理 ==================
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
            endTime: startTime.add(duration),
            totalRewards: totalReward,
            claimedRewards: 0,
            rewardsToken: rewardsToken
        });

        emit RewardScheduleAdded(scheduleId);
    }

    // ================== 奖励计算 ==================
    function earned(address account) public view returns (uint256 total) {
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            total = total.add(_earnedPerSchedule(account, i));
        }
    }

    function _earnedPerSchedule(address account, uint256 scheduleId) private view returns (uint256) {
        RewardSchedule storage schedule = rewardSchedules[scheduleId];
        if (_balances[account] == 0 || block.timestamp < schedule.startTime) return 0;

        uint256 timeElapsed = block.timestamp.sub(schedule.startTime);
        uint256 totalDuration = schedule.endTime.sub(schedule.startTime);
        uint256 multiplier = timeElapsed.mul(1e18).div(totalDuration);

        uint256 availableRewards = schedule.totalRewards.sub(schedule.claimedRewards);
        uint256 userShare = _balances[account].mul(multiplier).div(_totalSupply);
        
        return availableRewards.mul(userShare).div(1e18).sub(_userAccrued[account][scheduleId]);
    }

    // ================== 奖励领取 ==================
    function claimRewards() external nonReentrant {
        _updateRewards(msg.sender);
        
        uint256 totalClaimed = 0;
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            RewardSchedule storage schedule = rewardSchedules[i];
            uint256 amount = _userAccrued[msg.sender][i];
            if (amount == 0) continue;

            // 安全检查
            require(
                schedule.claimedRewards.add(amount) <= schedule.totalRewards,
                "Over claimed"
            );
            
            _userAccrued[msg.sender][i] = 0;
            schedule.claimedRewards = schedule.claimedRewards.add(amount);
            
            _sendReward(schedule.rewardsToken, msg.sender, amount);
            totalClaimed = totalClaimed.add(amount);
        }

        require(totalClaimed > 0, "No rewards");
        emit RewardClaimed(msg.sender, totalClaimed, address(stakingToken));
    }

    // ================== 内部函数 ==================
    function _updateRewards(address account) internal {
        for (uint256 i = 1; i <= currentScheduleId; i++) {
            _userAccrued[account][i] = _userAccrued[account][i].add(_earnedPerSchedule(account, i));
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

    // ================== 视图函数 ==================
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
}
