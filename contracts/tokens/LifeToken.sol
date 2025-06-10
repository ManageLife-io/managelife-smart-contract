// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LifeToken is ERC20, Ownable {
    
    address private _pendingOwner;
    
    uint256 public constant TOKEN_UNIT = 1e18;
    uint256 public constant MAX_SUPPLY = 5e27;
    uint256 public constant INITIAL_SUPPLY = 2e27;
    uint256 public constant MIN_REBASE_INTERVAL_DAYS = 30;
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant MAX_REBASE_FACTOR = 10;
    uint256 public constant OWNERSHIP_TRANSFER_DELAY_DAYS = 2;

    struct RebaseConfig {
        uint256 lastRebaseTime;
        uint256 minRebaseInterval;
        uint256 rebaseFactor;
    }

    struct BaseBalanceRecord {
        uint256 amount;
        uint256 timestamp;
    }

    event BaseBalanceAdjusted(address indexed account, uint256 oldAmount, uint256 newAmount, uint256 timestamp);

    address public rebaser;
    address public distributor;
    bool public initialDistributionDone;
    
    RebaseConfig public rebaseConfig;
    mapping(address => bool) private _isExcludedFromRebase;
    mapping(address => uint256) private _baseBalances;
    mapping(address => BaseBalanceRecord[]) private _baseBalanceHistory;
    
    uint256 private _excludedFromRebaseTotal;

    event Rebase(uint256 indexed epoch, uint256 oldFactor, uint256 newFactor);
    
    uint256 public rebaseEpoch;
    event RebaserUpdated(address indexed newRebaser);
    event DistributorUpdated(address indexed newDistributor);
    event ExcludedFromRebase(address indexed account, bool oldExcluded, bool newExcluded);
    event Mint(address indexed recipient, uint256 amount);
    
    event BaseBalanceUpdated(address indexed account, uint256 oldBaseBalance, uint256 newBaseBalance, string reason);
    event ExcludedTotalUpdated(uint256 oldTotal, uint256 newTotal, address indexed triggerAccount, string reason);
    event RebaseFactorChanged(uint256 indexed epoch, uint256 oldFactor, uint256 newFactor, uint256 timestamp);
    event ExclusionStatusQueried(address indexed account, bool isExcluded, uint256 baseBalance, uint256 tokenBalance);

    modifier onlyRebaser() {
        require(msg.sender == rebaser, "Caller is not the rebaser");
        _;
    }

    modifier onlyDistributor() {
        require(msg.sender == distributor, "Caller is not the distributor");
        _;
    }

    constructor(address initialOwner_)
        ERC20("ManageLife Token", "Life")
        Ownable()
    {
        require(initialOwner_ != address(0), "Zero address not allowed");
        
        rebaser = initialOwner_;
        distributor = initialOwner_;

        rebaseConfig = RebaseConfig({
            lastRebaseTime: block.timestamp,
            minRebaseInterval: MIN_REBASE_INTERVAL_DAYS * SECONDS_PER_DAY,
            rebaseFactor: TOKEN_UNIT // 1:1
        });

        _baseBalances[address(this)] = INITIAL_SUPPLY;
        emit Transfer(address(0), address(this), INITIAL_SUPPLY);
    }

    // =============================
    // Main Functions
    // =============================
    
    /**
     * @dev Executes supply adjustment
     * @param newFactor_ New adjustment factor (based on 1e18, e.g., 1.1e18 means +10%)
     */
    /// @notice Adjusts the token's supply elastically through a rebase operation
    /// @dev Can only be called by the rebaser role after minimum interval has passed
    /// @param newFactor_ New rebase factor (TOKEN_UNIT based, e.g., 1.1e18 for +10%)
    function rebase(uint256 newFactor_) external onlyRebaser {
        require(
            block.timestamp >= rebaseConfig.lastRebaseTime + rebaseConfig.minRebaseInterval,
            "Rebase interval not reached"
        );
        
        require(newFactor_ > 0, "Rebase factor must be positive");
        require(newFactor_ <= MAX_REBASE_FACTOR * TOKEN_UNIT, "Rebase factor too large"); // Max 10x increase
        
        // Calculate prospective supply based on current total supply, not just INITIAL_SUPPLY
        // This fixes the unreachable remaining supply vulnerability
        uint256 currentSupply = totalSupply();
        
        // Calculate the non-excluded portion that will be affected by rebase
        uint256 nonExcludedCurrentSupply = currentSupply - _excludedFromRebaseTotal;
        
        // Prevent overflow in multiplication by checking limits
        require(
            nonExcludedCurrentSupply <= MAX_SUPPLY / MAX_REBASE_FACTOR,
            "Current supply too large for safe rebase calculation"
        );
        
        // Calculate what the new total supply would be after rebase
        // Use safe math to prevent overflow
        uint256 prospectiveNonExcludedSupply = (nonExcludedCurrentSupply * newFactor_) / rebaseConfig.rebaseFactor;
        
        // Check for overflow in addition
        require(
            prospectiveNonExcludedSupply <= MAX_SUPPLY - _excludedFromRebaseTotal,
            "Rebase calculation would cause overflow"
        );
        
        uint256 prospectiveSupply = prospectiveNonExcludedSupply + _excludedFromRebaseTotal;
        
        require(prospectiveSupply <= MAX_SUPPLY, "Rebase would exceed MAX_SUPPLY");
        
        uint256 oldFactor = rebaseConfig.rebaseFactor;
        rebaseConfig.rebaseFactor = newFactor_;
        rebaseConfig.lastRebaseTime = block.timestamp;
        
        rebaseEpoch += 1;
        emit Rebase(rebaseEpoch, oldFactor, newFactor_);
        emit RebaseFactorChanged(rebaseEpoch, oldFactor, newFactor_, block.timestamp);
    }
    
    function totalSupply() public view override returns (uint256) {
        uint256 rebaseFactor = rebaseConfig.rebaseFactor;
        
        uint256 nonExcludedSupply = INITIAL_SUPPLY - _excludedFromRebaseTotal;
        uint256 rebasedSupply = (nonExcludedSupply * rebaseFactor) / TOKEN_UNIT;
        
        return rebasedSupply + _excludedFromRebaseTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(account != address(0), "Zero address not allowed");
        
        if (_isExcludedFromRebase[account]) {
            return _baseBalances[account];
        }
        
        return (_baseBalances[account] * rebaseConfig.rebaseFactor) / TOKEN_UNIT;
    }

    function initialDistribution(
        address[] calldata recipients_,
        uint256[] calldata amounts_
    ) external onlyDistributor {
        require(!initialDistributionDone, "Distribution already completed");
        require(recipients_.length == amounts_.length, "Array length mismatch");

        uint256 totalDistributed;
        for (uint256 i = 0; i < recipients_.length; i++) {
            require(recipients_[i] != address(0), "Invalid recipient address");
            uint256 amount = amounts_[i] * 1e6 * TOKEN_UNIT; // Convert millions to wei
            
            // Calculate base amount for recipient
            uint256 baseAmount = _isExcludedFromRebase[recipients_[i]]
                ? amount  // Excluded: use token amount directly as base units
                : (amount * TOKEN_UNIT) / rebaseConfig.rebaseFactor;  // Non-excluded: convert to base units
            
            // Update base balances
            _baseBalances[recipients_[i]] = _baseBalances[recipients_[i]] + baseAmount;
            _baseBalances[address(this)] = _baseBalances[address(this)] - amount; // Contract always uses token amount
            
            // Update excluded total if recipient is excluded - 修复排除地址供应量操纵漏洞
            if (_isExcludedFromRebase[recipients_[i]]) {
                _excludedFromRebaseTotal = _excludedFromRebaseTotal + baseAmount; // 使用基础单位而非代币数量
            }
            
            totalDistributed = totalDistributed + amount;
            emit Transfer(address(this), recipients_[i], amount);
        }

        require(totalDistributed <= INITIAL_SUPPLY, "Distribution exceeds initial supply");
        initialDistributionDone = true;
    }

    // =============================
    // Internal Function
    // =============================
    
    /**
     * @dev Rewrites the transfer logic
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
    
        uint256 senderBalance = balanceOf(sender);
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
    
        // Convert to base unit for sender
        uint256 baseAmountSender = _isExcludedFromRebase[sender]
            ? amount  // Excluded: 1 token = 1 base unit
            : (amount * TOKEN_UNIT) / rebaseConfig.rebaseFactor;  // Non-excluded: convert to base units
    
        // Convert to base unit for recipient
        uint256 baseAmountRecipient = _isExcludedFromRebase[recipient]
            ? amount  // Excluded: 1 token = 1 base unit
            : (amount * TOKEN_UNIT) / rebaseConfig.rebaseFactor;  // Non-excluded: convert to base units
    
        // Fix: Consistent handling of excluded total tracking
        // Use token amount (which equals base amount for excluded accounts) for consistency
        if (_isExcludedFromRebase[sender] && !_isExcludedFromRebase[recipient]) {
            // Transfer from excluded to non-excluded: subtract token amount from excluded total
            _excludedFromRebaseTotal = _excludedFromRebaseTotal - amount;
        } else if (!_isExcludedFromRebase[sender] && _isExcludedFromRebase[recipient]) {
            // Transfer from non-excluded to excluded: add token amount to excluded total
            _excludedFromRebaseTotal = _excludedFromRebaseTotal + amount;
        }
        // If both are excluded or both are non-excluded, _excludedFromRebaseTotal remains unchanged
    
        // Update base balances directly without calling super._transfer
        _baseBalances[sender] = _baseBalances[sender] - baseAmountSender;
        _baseBalances[recipient] = _baseBalances[recipient] + baseAmountRecipient;
    
        emit Transfer(sender, recipient, amount);
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
        
        // Fix: Use base balance instead of token balance for consistency
        // When excluding an account, we need to add their base balance to excluded total
        // since excluded accounts store token amounts directly as base amounts
        uint256 currentBaseBalance = _baseBalances[account_];
        uint256 oldExcludedTotal = _excludedFromRebaseTotal;
        _excludedFromRebaseTotal = _excludedFromRebaseTotal + currentBaseBalance;
        
        _isExcludedFromRebase[account_] = true;
        emit ExcludedFromRebase(account_, previousExclusion, true);
        emit ExcludedTotalUpdated(oldExcludedTotal, _excludedFromRebaseTotal, account_, "Account excluded from rebase");
    }

    /// @notice Includes an account in rebase effects
    /// @dev Can only be called by the contract owner
    /// @param account The address to include in rebase
    function includeInRebase(address account) external onlyOwner {
        require(account != address(0), "Zero address not allowed");
        bool previousExclusion = _isExcludedFromRebase[account];
        require(previousExclusion, "Account not excluded");
        
        // Fix: Use base balance for consistency with excludeFromRebase
        // For excluded accounts, base balance equals token balance
        uint256 currentBaseBalance = _baseBalances[account];
        uint256 oldExcludedTotal = _excludedFromRebaseTotal;
        _excludedFromRebaseTotal = _excludedFromRebaseTotal - currentBaseBalance;
        
        _isExcludedFromRebase[account] = false;
        emit ExcludedFromRebase(account, previousExclusion, false);
        emit ExcludedTotalUpdated(oldExcludedTotal, _excludedFromRebaseTotal, account, "Account included in rebase");
    }

    /// @notice Mints the remaining supply up to MAX_SUPPLY
    /// @dev Can only be called by the owner
    /// @param recipient Address to receive the minted tokens
    function mintRemainingSupply(address recipient) external onlyOwner {
        require(recipient != address(0), "Cannot mint to zero address");
        uint256 currentTotal = totalSupply();
        require(currentTotal < MAX_SUPPLY, "Max supply already minted");
        uint256 remaining = MAX_SUPPLY - currentTotal;
        
        // Additional safety check: ensure remaining amount is reasonable
        require(remaining > 0, "No remaining supply to mint");
        require(remaining <= MAX_SUPPLY / 2, "Remaining supply too large for single mint");
        
        // Check that minting won't cause issues with future rebase operations
        uint256 prospectiveTotal = currentTotal + remaining;
        require(prospectiveTotal <= MAX_SUPPLY, "Mint would exceed MAX_SUPPLY");
        
        // Use the custom _mint function to properly handle supply tracking
        _mint(recipient, remaining);
        
        emit Mint(recipient, remaining);
    }
    
    /**
     * @dev Override _mint to properly handle rebase mechanics and supply tracking
     * @param account The account to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function _mint(address account, uint256 amount) internal override {
        require(account != address(0), "ERC20: mint to the zero address");
        require(amount > 0, "Cannot mint zero amount");
        
        // Check that minting won't exceed MAX_SUPPLY
        uint256 currentTotal = totalSupply();
        require(currentTotal + amount <= MAX_SUPPLY, "Mint would exceed MAX_SUPPLY");
        
        // Calculate base amount correctly
        uint256 baseAmount = _isExcludedFromRebase[account]
            ? amount  // Excluded: mint token amount directly as base units
            : (amount * TOKEN_UNIT) / rebaseConfig.rebaseFactor;  // Non-excluded: convert to base units
        
        // Additional overflow protection for base amount calculation
        if (!_isExcludedFromRebase[account]) {
            require(
                amount <= (type(uint256).max / TOKEN_UNIT) * rebaseConfig.rebaseFactor,
                "Amount too large for base calculation"
            );
        }
        
        uint256 oldBalance = _baseBalances[account];
        
        // Check for overflow in balance addition
        require(
            _baseBalances[account] <= type(uint256).max - baseAmount,
            "Balance overflow in mint"
        );
        
        _baseBalances[account] = _baseBalances[account] + baseAmount;
        
        // Update excluded total if recipient is excluded from rebase
        if (_isExcludedFromRebase[account]) {
            // Check for overflow in excluded total
            require(
                _excludedFromRebaseTotal <= type(uint256).max - baseAmount,
                "Excluded total overflow in mint"
            );
            _excludedFromRebaseTotal = _excludedFromRebaseTotal + baseAmount;
        }
        
        _logBaseBalanceChange(account, oldBalance, _baseBalances[account]);
        
        // Do NOT call super._mint as it would interfere with our custom balance tracking
        // Instead, emit the Transfer event directly
        emit Transfer(address(0), account, amount);
    }
    
    /**
     * @dev Override _burn to properly handle rebase mechanics and supply tracking
     * @param account The account to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function _burn(address account, uint256 amount) internal override {
        require(account != address(0), "ERC20: burn from the zero address");
        require(amount > 0, "Cannot burn zero amount");
        
        uint256 accountBalance = balanceOf(account);
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        
        // Calculate base amount to burn
        uint256 baseAmount = _isExcludedFromRebase[account]
            ? amount  // Excluded: burn token amount directly as base units
            : (amount * TOKEN_UNIT) / rebaseConfig.rebaseFactor;  // Non-excluded: convert to base units
        
        // Additional overflow protection for base amount calculation
        if (!_isExcludedFromRebase[account]) {
            require(
                amount <= (type(uint256).max / TOKEN_UNIT) * rebaseConfig.rebaseFactor,
                "Amount too large for base calculation"
            );
        }
        
        uint256 oldBalance = _baseBalances[account];
        
        // Ensure base balance is sufficient
        require(_baseBalances[account] >= baseAmount, "Base balance insufficient for burn");
        
        _baseBalances[account] = _baseBalances[account] - baseAmount;
        
        // Update excluded total if account is excluded from rebase
        if (_isExcludedFromRebase[account]) {
            // Ensure excluded total is sufficient
            require(_excludedFromRebaseTotal >= baseAmount, "Excluded total insufficient for burn");
            _excludedFromRebaseTotal = _excludedFromRebaseTotal - baseAmount;
        }
        
        _logBaseBalanceChange(account, oldBalance, _baseBalances[account]);
        
        // Do NOT call super._burn as it would interfere with our custom balance tracking
        // Instead, emit the Transfer event directly
        emit Transfer(account, address(0), amount);
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

    /// @notice 获取被排除在rebase外的地址的基础余额总和
    /// @return 排除地址的基础余额总和
    function getExcludedFromRebaseTotal() external view returns (uint256) {
        return _excludedFromRebaseTotal;
    }
    
    /// @notice Gets detailed account information for transparency
    /// @param account Address to query
    /// @return isExcluded Whether account is excluded from rebase
    /// @return baseBalance The base balance of the account
    /// @return tokenBalance The current token balance of the account
    /// @return rebaseFactor Current rebase factor
    function getAccountDetails(address account) external returns (bool isExcluded, uint256 baseBalance, uint256 tokenBalance, uint256 rebaseFactor) {
        require(account != address(0), "Zero address not allowed");
        
        isExcluded = _isExcludedFromRebase[account];
        baseBalance = _baseBalances[account];
        tokenBalance = balanceOf(account);
        rebaseFactor = rebaseConfig.rebaseFactor;
        
        // Emit event for transparency
        emit ExclusionStatusQueried(account, isExcluded, baseBalance, tokenBalance);
    }
    
    /// @notice Gets the base balance of an account (internal balance before rebase calculation)
    /// @param account Address to check
    /// @return The base balance amount
    function getBaseBalance(address account) external view returns (uint256) {
        require(account != address(0), "Zero address not allowed");
        return _baseBalances[account];
    }
    
    /// @notice Gets comprehensive rebase information
    /// @return currentFactor Current rebase factor
    /// @return lastRebaseTime Timestamp of last rebase
    /// @return minInterval Minimum interval between rebases
    /// @return epoch Current rebase epoch
    /// @return excludedTotal Total excluded from rebase
    /// @return participatingSupply Supply participating in rebase
    function getRebaseInfo() external view returns (
        uint256 currentFactor,
        uint256 lastRebaseTime,
        uint256 minInterval,
        uint256 epoch,
        uint256 excludedTotal,
        uint256 participatingSupply
    ) {
        currentFactor = rebaseConfig.rebaseFactor;
        lastRebaseTime = rebaseConfig.lastRebaseTime;
        minInterval = rebaseConfig.minRebaseInterval;
        epoch = rebaseEpoch;
        excludedTotal = _excludedFromRebaseTotal;
        participatingSupply = INITIAL_SUPPLY - _excludedFromRebaseTotal;
    }

    uint256 constant OWNERSHIP_TRANSFER_DELAY = OWNERSHIP_TRANSFER_DELAY_DAYS * SECONDS_PER_DAY;
    uint256 public ownershipTransferTime;

    function _logBaseBalanceChange(address account, uint256 oldAmount, uint256 newAmount) private {
        // Only log if there's an actual change in balance to prevent duplicate entries
        if (oldAmount != newAmount) {
            // Ensure closure correctness by capturing all required state
            BaseBalanceRecord[] storage records = _baseBalanceHistory[account];
            
            // Additional check: prevent duplicate consecutive entries with same amount and timestamp
            if (records.length == 0 || 
                records[records.length - 1].amount != newAmount || 
                records[records.length - 1].timestamp != block.timestamp) {
                
                records.push(BaseBalanceRecord({
                    amount: newAmount,
                    timestamp: block.timestamp
                }));
                emit BaseBalanceAdjusted(account, oldAmount, newAmount, block.timestamp);
                emit BaseBalanceUpdated(account, oldAmount, newAmount, "Balance change logged");
            }
        }
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