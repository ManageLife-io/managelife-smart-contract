// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title LifeToken - An ERC20 token with elastic supply mechanism
/// @notice This contract implements a rebasing ERC20 token with initial distribution functionality
/// @dev Inherits from OpenZeppelin's ERC20 and Ownable contracts
/// @dev Implements a rebase mechanism that can adjust total supply and user balances
/// @dev Features include:
///      - Elastic supply through rebase mechanism
///      - Initial token distribution system
///      - Exclusion of addresses from rebase effects
///      - Owner-controlled rebase parameters
contract LifeToken is ERC20, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    
    address private _pendingOwner;
    // =============================
    // Constants
    // =============================
    uint256 public constant TOKEN_UNIT = 1e18;                      // Base unit for token calculations (1e18 = 1 token)
    uint256 public constant MAX_SUPPLY = 5e27;                      // 5 billion tokens (5e27 = 5_000_000_000 * TOKEN_UNIT)
    uint256 public constant INITIAL_SUPPLY = 2e27;                  // Initial 2 billion tokens (2e27 = 2_000_000_000 * TOKEN_UNIT)
    uint256 public constant MIN_SUPPLY = 1e24;                      // Minimum supply (1 million tokens)
    uint256 public constant REBASE_FACTOR_PRECISION = 1e18;         // Precision for rebase factor calculations
    uint256 public constant MAX_REBASE_FACTOR = 10e18;              // Maximum rebase factor (10x)

    // =============================
    // Data Structures
    // =============================
    struct RebaseConfig {
        uint256 lastRebaseTimestamp;   // Last rebase timestamp (renamed for clarity)
        uint256 minRebaseInterval;     // Minimum interval (seconds)
        uint256 rebaseFactor;          // Rebase factor (based on TOKEN_UNIT)
        uint256 epoch;                 // Current rebase epoch
    }

    struct BaseBalanceRecord {
        uint256 amount;
        uint256 timestamp;
    }

    event BaseBalanceAdjusted(address indexed account, uint256 oldAmount, uint256 newAmount, uint256 timestamp);

    // =============================
    // State Variables
    // =============================
    address public rebaser;       // Rebase operator
    address public distributor;   // Initial distribution address
    bool public initialDistributionDone; // Initial distribution status
    
    RebaseConfig public rebaseConfig;     // Rebase configuration
    mapping(address => bool) private _isExcludedFromRebase; // Excluded addresses list (renamed for clarity)
    mapping(address => uint256) private _baseBalances;      // Base balance storage
    mapping(address => BaseBalanceRecord[]) private _baseBalanceHistory; // Historical balance records
    
    // Track total base balance and excluded portion
    uint256 private _totalBaseBalance;
    uint256 private _totalBaseBalanceExcluded;

    // =============================
    // Events
    // =============================
    event Rebase(uint256 indexed epoch, uint256 oldFactor, uint256 newFactor);
    event EmergencyRebase(uint256 indexed epoch, uint256 oldFactor, uint256 newFactor, address indexed caller);

    uint256 public rebaseEpoch; // Track number of rebase operations
    event RebaserUpdated(address indexed newRebaser);
    event DistributorUpdated(address indexed newDistributor);
    event ExcludedFromRebase(address indexed account, bool oldExcluded, bool newExcluded);
    event Mint(address indexed recipient, uint256 amount);

    // =============================
    // Modifiers
    // =============================
    modifier onlyRebaser() {
        require(msg.sender == rebaser, "Caller is not the rebaser");
        _;
    }

    modifier onlyDistributor() {
        require(msg.sender == distributor, "Caller is not the distributor");
        _;
    }

    // =============================
    // Constructor
    // =============================
    /// @notice Initializes the LifeToken contract
    /// @dev Sets up initial token parameters, ownership, and mints initial supply
    /// @param initialOwner_ The address that will receive initial ownership and control
    constructor(address initialOwner_)
        ERC20("ManageLife Token", "Life")
    {
        require(initialOwner_ != address(0), "Zero address not allowed");
        
        // Transfer ownership to the specified address
        _transferOwnership(initialOwner_);
        
        rebaser = initialOwner_;
        distributor = initialOwner_;

        rebaseConfig = RebaseConfig({
            lastRebaseTimestamp: block.timestamp,
            minRebaseInterval: 30 days,
            rebaseFactor: TOKEN_UNIT, // 1:1
            epoch: 0
        });

        _baseBalances[address(this)] = INITIAL_SUPPLY;
        _totalBaseBalance = INITIAL_SUPPLY;
        
        emit Transfer(address(0), address(this), INITIAL_SUPPLY);
    }

    // =============================
    // Main Functions
    // =============================
    
    /**
     * @dev Executes supply adjustment
     * @param newFactor_ New adjustment factor (based on 1e18, e.g., 1.1e18 means +10%)
     */

    /// @notice Performs a rebase operation to adjust token supply
    /// @dev Only callable by the rebaser, with minimum interval enforcement and change limits
    /// @param newRebaseFactor The new rebase factor (scaled by 1e18)
    function rebase(uint256 newRebaseFactor) external onlyRebaser {
        require(
            block.timestamp >= rebaseConfig.lastRebaseTimestamp + rebaseConfig.minRebaseInterval,
            "Rebase interval not met"
        );

        // Use SafeMath-like checks for precision
        require(newRebaseFactor > 0, "Invalid rebase factor");
        require(newRebaseFactor <= MAX_REBASE_FACTOR, "Rebase factor too high");

        // Add protection against extreme rebase changes (audit fix)
        uint256 currentFactor = rebaseConfig.rebaseFactor;
        uint256 maxChangePercent = 20; // Maximum 20% change per rebase
        uint256 maxIncrease = currentFactor * (100 + maxChangePercent) / 100;
        uint256 maxDecrease = currentFactor * (100 - maxChangePercent) / 100;

        require(
            newRebaseFactor <= maxIncrease && newRebaseFactor >= maxDecrease,
            "Rebase change exceeds maximum allowed (20%)"
        );

        // Calculate new supply with higher precision
        uint256 newSupply = (_totalBaseBalance * newRebaseFactor) / REBASE_FACTOR_PRECISION;
        require(newSupply <= MAX_SUPPLY, "Supply exceeds maximum");
        require(newSupply >= MIN_SUPPLY, "Supply below minimum");

        uint256 oldFactor = rebaseConfig.rebaseFactor;

        // Update rebase configuration
        rebaseConfig.rebaseFactor = newRebaseFactor;
        rebaseConfig.lastRebaseTimestamp = block.timestamp;
        rebaseConfig.epoch++;

        emit Rebase(rebaseConfig.epoch, oldFactor, newRebaseFactor);
    }

    /// @notice Emergency rebase function that bypasses the 20% change limit
    /// @dev Only callable by the contract owner in emergency situations
    /// @param newRebaseFactor The new rebase factor (scaled by 1e18)
    function emergencyRebase(uint256 newRebaseFactor) external onlyOwner {
        require(
            block.timestamp >= rebaseConfig.lastRebaseTimestamp + rebaseConfig.minRebaseInterval,
            "Rebase interval not met"
        );

        require(newRebaseFactor > 0, "Invalid rebase factor");
        require(newRebaseFactor <= MAX_REBASE_FACTOR, "Rebase factor too high");

        // Calculate new supply with higher precision
        uint256 newSupply = (_totalBaseBalance * newRebaseFactor) / REBASE_FACTOR_PRECISION;
        require(newSupply <= MAX_SUPPLY, "Supply exceeds maximum");
        require(newSupply >= MIN_SUPPLY, "Supply below minimum");

        uint256 oldFactor = rebaseConfig.rebaseFactor;

        // Update rebase configuration
        rebaseConfig.rebaseFactor = newRebaseFactor;
        rebaseConfig.lastRebaseTimestamp = block.timestamp;
        rebaseConfig.epoch++;

        emit EmergencyRebase(rebaseConfig.epoch, oldFactor, newRebaseFactor, msg.sender);
    }

    /// @notice Returns the balance of an account after applying rebase factor
    /// @dev Accounts for whether the account is excluded from rebase
    /// @param account The address to check balance for
    /// @return The current balance of the account
    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcludedFromRebase[account]) {
            return _baseBalances[account];
        }
        return (_baseBalances[account] * rebaseConfig.rebaseFactor) / REBASE_FACTOR_PRECISION;
    }

    /// @notice Returns the total token supply after applying rebase factor
    /// @dev Accounts for both rebased and excluded token portions
    /// @return The current total supply
    function totalSupply() public view override returns (uint256) {
        // Calculate rebased portion with higher precision
        uint256 rebasedPortion = ((_totalBaseBalance - _totalBaseBalanceExcluded) * rebaseConfig.rebaseFactor) / REBASE_FACTOR_PRECISION;
        
        // Add excluded portion (not affected by rebase)
        return rebasedPortion + _totalBaseBalanceExcluded;
    }

    // =============================
    // Public Transfer Functions with Reentrancy Protection
    // =============================

    /// @notice Transfer tokens with reentrancy protection
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @return success True if transfer succeeded
    function transfer(address to, uint256 amount) public override nonReentrant returns (bool) {
        return super.transfer(to, amount);
    }

    /// @notice Transfer tokens from one address to another with reentrancy protection
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @return success True if transfer succeeded
    function transferFrom(address from, address to, uint256 amount) public override nonReentrant returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    // =============================
    // Internal Function
    // =============================
    
    /**
     * @dev Rewrites the transfer logic
     */
    /// @notice Internal transfer function with rebase handling
    /// @dev Overrides ERC20 transfer to handle base balance adjustments
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer (in current supply terms)
    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "Transfer from zero address");
        require(to != address(0), "Transfer to zero address");
        
        // Convert amount to base balance with higher precision
        uint256 baseAmount;
        
        if (_isExcludedFromRebase[from]) {
            // From excluded: amount is already in base terms
            baseAmount = amount;
        } else {
            // From non-excluded: convert from rebased to base
            baseAmount = (amount * REBASE_FACTOR_PRECISION) / rebaseConfig.rebaseFactor;
        }
        
        require(_baseBalances[from] >= baseAmount, "Insufficient balance");
        
        // Update base balances
        _baseBalances[from] -= baseAmount;
        _baseBalances[to] += baseAmount;
        
        // Update excluded totals if necessary
        if (_isExcludedFromRebase[from] && !_isExcludedFromRebase[to]) {
            // From excluded to non-excluded
            _totalBaseBalanceExcluded -= baseAmount;
        } else if (!_isExcludedFromRebase[from] && _isExcludedFromRebase[to]) {
            // From non-excluded to excluded
            _totalBaseBalanceExcluded += baseAmount;
        }
        
        emit Transfer(from, to, amount);
    }

    // =============================
    // Management Function
    // =============================
    
    /// @notice Updates the address authorized to perform rebase operations
    /// @dev Can only be called by the contract owner
    /// @param newRebaser_ The new rebaser address
    function setRebaser(address newRebaser_) external onlyOwner {
        require(newRebaser_ != address(0), "Invalid address");
        rebaser = newRebaser_;
        emit RebaserUpdated(newRebaser_);
    }

    /// @notice Updates the address authorized to perform initial distribution
    /// @dev Can only be called by the owner before initial distribution is completed
    /// @param newDistributor_ The new distributor address
    function setDistributor(address newDistributor_) external onlyOwner {
        require(!initialDistributionDone, "Distribution already completed");
        distributor = newDistributor_;
        emit DistributorUpdated(newDistributor_);
    }

    /// @notice Excludes an account from rebase effects
    /// @dev Can only be called by the contract owner
    /// @param account_ The address to exclude from rebase
    function excludeFromRebase(address account_) external onlyOwner {
        require(account_ != address(0), "Zero address not allowed");
        bool previousExclusion = _isExcludedFromRebase[account_];
        require(!previousExclusion, "Account already excluded");
        
        // Update total base balance for excluded accounts
        _totalBaseBalanceExcluded = _totalBaseBalanceExcluded.add(_baseBalances[account_]);
        
        _isExcludedFromRebase[account_] = true;
        emit ExcludedFromRebase(account_, previousExclusion, true);
    }

    /// @notice Includes an account in rebase effects
    /// @dev Can only be called by the contract owner
    /// @param account The address to include in rebase
    function includeInRebase(address account) external onlyOwner {
        require(account != address(0), "Zero address not allowed");
        bool previousExclusion = _isExcludedFromRebase[account];
        require(previousExclusion, "Account not excluded");
        
        // Subtract from total base balance of excluded accounts
        _totalBaseBalanceExcluded = _totalBaseBalanceExcluded.sub(_baseBalances[account]);
        
        _isExcludedFromRebase[account] = false;
        emit ExcludedFromRebase(account, previousExclusion, false);
    }

    /// @notice Mints the remaining supply up to MAX_SUPPLY
    /// @dev Can only be called by the owner
    /// @param recipient Address to receive the minted tokens
    function mintRemainingSupply(address recipient) external onlyOwner {
        require(recipient != address(0), "Cannot mint to zero address");
        uint256 currentTotal = totalSupply();
        require(currentTotal < MAX_SUPPLY, "Max supply already minted");
        uint256 remaining = MAX_SUPPLY - currentTotal;
        uint256 baseAmount = _isExcludedFromRebase[recipient]
            ? remaining  // Excluded: mint token amount directly
            : remaining.mul(TOKEN_UNIT).div(rebaseConfig.rebaseFactor);  // Non-excluded: convert to base units
        
        uint256 oldBalance = _baseBalances[recipient];
        _baseBalances[recipient] += baseAmount;
        _totalBaseBalance += baseAmount;
        
        // If recipient is excluded from rebase, update excluded total balance
        if (_isExcludedFromRebase[recipient]) {
            _totalBaseBalanceExcluded = _totalBaseBalanceExcluded.add(baseAmount);
        }
        
        _logBaseBalanceChange(recipient, oldBalance, _baseBalances[recipient]);
        
        emit Transfer(address(0), recipient, remaining);
        emit Mint(recipient, remaining);
    }

    /// @notice Gets historical base balance records for an account
    /// @param account Address to check balance history for
    /// @return Array of BaseBalanceRecord structs
    function getBaseBalanceHistory(address account) external view returns (BaseBalanceRecord[] memory) {
        require(account != address(0), "Zero address not allowed");
        return _baseBalanceHistory[account];
    }

    /// @notice Checks if an account is excluded from rebase
    /// @param account Address to check exclusion status
    /// @return Boolean indicating exclusion status
    function isExcludedFromRebase(address account) external view returns (bool) {
        require(account != address(0), "Zero address not allowed");
        return _isExcludedFromRebase[account];
    }

    /// @notice Gets the total base balance of addresses excluded from rebase
    /// @return Total base balance of excluded addresses
    function getExcludedFromRebaseTotal() external view returns (uint256) {
        return _totalBaseBalanceExcluded;
    }

    uint256 constant OWNERSHIP_TRANSFER_DELAY = 2 * 86400;
    uint256 public ownershipTransferTime;

    function _logBaseBalanceChange(address account, uint256 oldAmount, uint256 newAmount) private {
        // Ensure closure correctness by capturing all required state
        BaseBalanceRecord[] storage records = _baseBalanceHistory[account];
        records.push(BaseBalanceRecord({
            amount: newAmount,
            timestamp: block.timestamp
        }));
        emit BaseBalanceAdjusted(account, oldAmount, newAmount, block.timestamp);
    }
    // =============================
    // Security Improvements
    // =============================

    event OwnershipTransferStarted(address indexed pendingOwner);
    event OwnershipTransferCanceled(address indexed canceledOwner);

    // Modifier to ensure ownership transfer is ready
    modifier onlyWhenTransferReady() {
        require(_pendingOwner != address(0), "No pending transfer");
        require(block.timestamp >= ownershipTransferTime, "Transfer delay not met");
        _;
    }

    /// @notice Initiates ownership transfer to new owner
    /// @dev Starts 2-day transfer timer
    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "Invalid address");
        _pendingOwner = newOwner;
        ownershipTransferTime = block.timestamp + OWNERSHIP_TRANSFER_DELAY;
        emit OwnershipTransferStarted(newOwner);
    }

    /// @notice Completes ownership transfer after delay
    function acceptOwnership() external onlyWhenTransferReady {
        require(msg.sender == _pendingOwner, "Caller not pending owner");
        _transferOwnership(_pendingOwner);
        _pendingOwner = address(0);
        ownershipTransferTime = 0;
    }

    /// @notice Cancels pending ownership transfer
    function cancelOwnershipTransfer() external onlyOwner {
        require(_pendingOwner != address(0), "No pending transfer");
        emit OwnershipTransferCanceled(_pendingOwner);
        _pendingOwner = address(0);
        ownershipTransferTime = 0;
    }

    //@audit Disable dangerous renouncement function
    function renounceOwnership() public view override onlyOwner {
        revert("Ownership renunciation disabled");
    }
}