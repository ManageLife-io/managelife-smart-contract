// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../libraries/StakingConstants.sol";

function _earnedPerSchedule(address account, uint256 scheduleId) private view returns (uint256) {
    RewardSchedule storage schedule = rewardSchedules[scheduleId];
    if (_snapshotBalances[account] == 0 || block.timestamp < schedule.startTime) return 0;
    
    // Check if schedule has ended
    if (block.timestamp >= schedule.endTime) {
        return 0;
    }

    // Additional boundary check
    uint256 totalDuration = schedule.endTime - schedule.startTime;
    require(totalDuration > 0, "Invalid schedule duration");
    
    uint256 timeElapsed = block.timestamp - schedule.startTime;
    if (timeElapsed > totalDuration) {
        timeElapsed = totalDuration;
    }

    // Calculate rewards based on the actual elapsed time within schedule duration
    uint256 effectiveTimeElapsed = Math.min(timeElapsed, totalDuration);
    uint256 multiplier = effectiveTimeElapsed * MULTIPLIER / totalDuration;
    
    // Calculate available rewards considering already claimed rewards
    uint256 remainingRewards = schedule.totalRewards - schedule.claimedRewards;
    uint256 availableRewards = Math.min(
        schedule.totalRewards * effectiveTimeElapsed / totalDuration,
        remainingRewards
    );
    
    // Calculate user's share of rewards
    uint256 userShare = _balances[account] * multiplier / _totalSupply;
    uint256 userRewards = availableRewards * userShare / TOKEN_UNIT;
    
    // Ensure we don't exceed remaining rewards
    userRewards = Math.min(userRewards, remainingRewards);
    
    // Subtract already accrued rewards
    return userRewards > _userAccrued[account][scheduleId] ? 
           userRewards - _userAccrued[account][scheduleId] : 0;
}

function claimRewards() external nonReentrant whenNotPaused {
    _updateRewards(msg.sender);
    
    uint256 totalClaimed = 0;
    for (uint256 i = 1; i <= currentScheduleId; i++) {
        RewardSchedule storage schedule = rewardSchedules[i];
        uint256 amount = _userAccrued[msg.sender][i];
        if (amount == 0) continue;

        // Ensure we don't exceed total rewards
        uint256 newClaimedRewards = schedule.claimedRewards + amount;
        require(newClaimedRewards <= schedule.totalRewards, "Exceeds total rewards");
        
        // Update state
        _userAccrued[msg.sender][i] = 0;
        schedule.claimedRewards = newClaimedRewards;
        
        // Transfer rewards
        _sendReward(schedule.rewardsToken, msg.sender, amount);
        totalClaimed = totalClaimed + amount;
        
        emit RewardClaimed(msg.sender, amount, schedule.rewardsToken);
    }

    require(totalClaimed > 0, "No rewards to claim");
} 