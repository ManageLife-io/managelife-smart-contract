// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// @title LifeToken - An ERC20 token with elastic supply mechanism
/// @notice This contract implements a rebasing ERC20 token with initial distribution functionality
/// @dev Inherits from OpenZeppelin's ERC20 and Ownable contracts
/// @dev Implements a rebase mechanism that can adjust total supply and user balances
/// @dev Features include:
///      - Elastic supply through rebase mechanism
///      - Initial token distribution system
///      - Exclusion of addresses from rebase effects
///      - Owner-controlled rebase parameters
contract LifeToken is ERC20, Ownable {
    using SafeMath for uint256;
    
    address private _pendingOwner;
    // =============================
    // Constants
    // =============================
    uint256 public constant TOKEN_UNIT = 1e18;                      // Base unit for token calculations (1e18 = 1 token)
    uint256 public constant MAX_SUPPLY = 5e27;                      // 5 billion tokens (5e27 = 5_000_000_000 * TOKEN_UNIT)
    uint256 public constant INITIAL_SUPPLY = 2e27;                  // Initial 2 billion tokens (2e27 = 2_000_000_000 * TOKEN_UNIT)

    // =============================
    // Data Structures
    // =============================
    struct RebaseConfig {
        uint256 lastRebaseTime;   // Last rebase time
        uint256 minRebaseInterval;// Minimum interval (seconds)
        uint256 rebaseFactor;     // Rebase factor (based on TOKEN_UNIT)
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
    mapping(address => bool) private _isExcludedFromRebase; // Excluded addresses list
    mapping(address => uint256) private _baseBalances;      // Base balance storage
    mapping(address => BaseBalanceRecord[]) private _baseBalanceHistory; // Historical balance records
    
    // 跟踪所有被排除在rebase外的地址的总基础余额
    uint256 private _excludedFromRebaseTotal;

    // =============================
    // Events
    // =============================
    event Rebase(uint256 indexed epoch, uint256 oldFactor, uint256 newFactor);
    
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
        Ownable()
    {
        require(initialOwner_ != address(0), "Zero address not allowed");
        
        rebaser = initialOwner_;
        distributor = initialOwner_;

        rebaseConfig = RebaseConfig({
            lastRebaseTime: block.timestamp,
            minRebaseInterval: 30 days,
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
        
        uint256 prospectiveSupply = (INITIAL_SUPPLY * newFactor_ + TOKEN_UNIT - 1) / TOKEN_UNIT; // Ceiling division without SafeMath dependency
        require(prospectiveSupply <= MAX_SUPPLY, "Rebase would exceed MAX_SUPPLY");
        
        uint256 oldFactor = rebaseConfig.rebaseFactor;
        rebaseConfig.rebaseFactor = newFactor_;
        rebaseConfig.lastRebaseTime = block.timestamp;
        
        rebaseEpoch += 1;
        emit Rebase(rebaseEpoch, oldFactor, newFactor_);
    }
    
    /**
     * @dev 获取调整后的总供应量，修复了计算错误
     * 正确计算总供应量 = 参与rebase部分的代币 + 不参与rebase部分的代币
     * 参与rebase部分 = (INITIAL_SUPPLY - 排除地址持有的基础余额总和) * rebaseFactor / TOKEN_UNIT
     * 不参与rebase部分 = 排除地址持有的基础余额总和
     */
    function totalSupply() public view override returns (uint256) {
        uint256 rebaseFactor = rebaseConfig.rebaseFactor;
        
        // 计算参与rebase的代币供应量（去除了排除地址持有的部分）
        uint256 nonExcludedSupply = INITIAL_SUPPLY.sub(_excludedFromRebaseTotal);
        uint256 rebasedSupply = nonExcludedSupply.mul(rebaseFactor).div(TOKEN_UNIT);
        
        // 总供应量 = rebase影响的部分 + 排除地址持有的代币数量
        return rebasedSupply.add(_excludedFromRebaseTotal);
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
    
        // Convert to base unit
        uint256 baseAmountSender = _isExcludedFromRebase[sender]
            ? amount  // Excluded: 1 token = 1 base unit
            : amount.mul(rebaseConfig.rebaseFactor).div(TOKEN_UNIT);  // Non-excluded: apply rebase
    
        uint256 baseAmountRecipient = _isExcludedFromRebase[recipient]
            ? amount  // Excluded: 1 token = 1 base unit
            : amount.mul(rebaseConfig.rebaseFactor).div(TOKEN_UNIT);  // Non-excluded: apply rebase
    
        // 调整排除账户的总余额跟踪
        if (_isExcludedFromRebase[sender] && !_isExcludedFromRebase[recipient]) {
            // 从排除名单中转出到非排除名单
            _excludedFromRebaseTotal = _excludedFromRebaseTotal.sub(baseAmountSender);
        } else if (!_isExcludedFromRebase[sender] && _isExcludedFromRebase[recipient]) {
            // 从非排除名单转入到排除名单
            _excludedFromRebaseTotal = _excludedFromRebaseTotal.add(baseAmountRecipient);
        } else if (_isExcludedFromRebase[sender] && _isExcludedFromRebase[recipient]) {
            // 两者都在排除名单，净影响是sender减少，recipient增加
            _excludedFromRebaseTotal = _excludedFromRebaseTotal.sub(baseAmountSender).add(baseAmountRecipient);
        }
    
        // Update base balance
        super._transfer(sender, recipient, amount);
        _baseBalances[sender] = _baseBalances[sender].sub(baseAmountSender);
        _baseBalances[recipient] = _baseBalances[recipient].add(baseAmountRecipient);
    
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
        
        // 更新排除账户的基础余额总和
        _excludedFromRebaseTotal = _excludedFromRebaseTotal.add(_baseBalances[account_]);
        
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
        
        // 从排除账户的基础余额总和中减去
        _excludedFromRebaseTotal = _excludedFromRebaseTotal.sub(_baseBalances[account]);
        
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
        
        // 如果接收者是排除在rebase外的地址，需要更新排除地址的总余额
        if (_isExcludedFromRebase[recipient]) {
            _excludedFromRebaseTotal = _excludedFromRebaseTotal.add(baseAmount);
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

    /// @notice 获取被排除在rebase外的地址的基础余额总和
    /// @return 排除地址的基础余额总和
    function getExcludedFromRebaseTotal() external view returns (uint256) {
        return _excludedFromRebaseTotal;
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