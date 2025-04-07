// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// @title BaseRewards - Basic staking and reward distribution contract
/// @notice Implements a staking mechanism where users can stake tokens and earn rewards
/// @dev Inherits from Ownable for access control and ReentrancyGuard for security
contract BaseRewards is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    // Staking asset (e.g., ERC20 token)
    IERC20 public stakingToken;
    // Reward token
    IERC20 public rewardsToken;

    // Reward rate parameters
    uint256 public rewardRate;     // Rewards per second
    uint256 public lastUpdateTime; // Last update timestamp
    uint256 public rewardPerTokenStored;

    // User configurations
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    constructor(
        address _stakingToken, 
        address _rewardsToken,
        address initialOwner
    ) {
        _transferOwnership(initialOwner);
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
    }

    /******************** Core Functions ********************/
    /// @notice Allows users to stake tokens
    /// @dev Updates rewards before processing stake
    /// @param amount Amount of tokens to stake
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Allows users to withdraw their staked tokens
    /// @dev Updates rewards before processing withdrawal
    /// @param amount Amount of tokens to withdraw
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Allows users to claim their accumulated rewards
    /// @dev Updates rewards before processing claim
    function claimReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.transfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /******************** Management Functions ********************/
    /// @notice Sets the reward rate for the staking contract
    /// @dev Only callable by contract owner
    /// @param _rewardRate New reward rate per second
    function setRewardRate(uint256 _rewardRate) external onlyOwner {
        rewardRate = _rewardRate;
    }

    /// @notice Allows owner to rescue any ERC20 tokens sent to the contract
    /// @dev Only callable by contract owner
    /// @param tokenAddress Address of the token to rescue
    /// @param amount Amount of tokens to rescue
    function rescueERC20(address tokenAddress, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).transfer(owner(), amount);
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
            _balances[account]
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    /// @notice Calculates the current reward per token stored
    /// @dev Used for reward distribution calculations
    /// @return Current reward per token rate
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                (block.timestamp.sub(lastUpdateTime)).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    /******************** Modifiers ********************/
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }
}
