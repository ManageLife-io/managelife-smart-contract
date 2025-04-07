// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

    // =============================
    // Constants
    // =============================
    uint256 public constant MAX_SUPPLY = 5_000_000_000 * 1e18;     // 5 billion
    uint256 public constant INITIAL_SUPPLY = 2_000_000_000 * 1e18; // Initial 2 billion

    // =============================
    // Data Structures
    // =============================
    struct RebaseConfig {
        uint256 lastRebaseTime;   // Last rebase time
        uint256 minRebaseInterval;// Minimum interval (seconds)
        uint256 rebaseFactor;     // Rebase factor (based on 1e18)
    }

    // =============================
    // State Variables
    // =============================
    address public rebaser;       // Rebase operator
    address public distributor;   // Initial distribution address
    bool public initialDistributionDone; // Initial distribution status
    
    RebaseConfig public rebaseConfig;     // Rebase configuration
    mapping(address => bool) private _isExcludedFromRebase; // Excluded addresses list
    mapping(address => uint256) private _baseBalances;      // Base balance storage

    // =============================
    // Events
    // =============================
    event Rebase(uint256 indexed epoch, uint256 oldFactor, uint256 newFactor);
    event RebaserUpdated(address indexed newRebaser);
    event DistributorUpdated(address indexed newDistributor);
    event ExcludedFromRebase(address indexed account, bool excluded);

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
        _transferOwnership(initialOwner_);
        
        rebaser = initialOwner_;
        distributor = initialOwner_;

        rebaseConfig = RebaseConfig({
            lastRebaseTime: block.timestamp,
            minRebaseInterval: 30 days,
            rebaseFactor: 1e18 // 1:1
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
    /// @param newFactor_ New rebase factor (1e18 based, e.g., 1.1e18 for +10%)
    function rebase(uint256 newFactor_) external onlyRebaser {
        require(
            block.timestamp >= rebaseConfig.lastRebaseTime.add(rebaseConfig.minRebaseInterval),
            "Rebase interval not reached"
        );
        require(
            newFactor_ <= 1.5e18 && newFactor_ >= 0.5e18,
            "Factor out of allowed range (0.5x - 1.5x)"
        );

        uint256 oldFactor = rebaseConfig.rebaseFactor;
        rebaseConfig.rebaseFactor = newFactor_;
        rebaseConfig.lastRebaseTime = block.timestamp;

        emit Rebase(block.timestamp, oldFactor, newFactor_);
    }

    /**
     * @dev Initial token distribution
     * @param recipients_ Array of addresses to receive tokens
     * @param amounts_ Array of token amounts in millions (e.g., 1 = 1M tokens)
     */
    /// @notice Performs the initial token distribution to specified addresses
    /// @dev Can only be called once by the distributor
    /// @param recipients_ Array of addresses to receive tokens
    /// @param amounts_ Array of token amounts in millions (e.g., 1 = 1M tokens)
    function initialDistribution(
        address[] calldata recipients_,
        uint256[] calldata amounts_
    ) external onlyDistributor {
        require(!initialDistributionDone, "Distribution already completed");
        require(recipients_.length == amounts_.length, "Array length mismatch");

        uint256 totalDistributed;
        for (uint256 i = 0; i < recipients_.length; i++) {
            uint256 amount = amounts_[i].mul(1e6 * 1e18); // 转换为wei单位
            _transfer(address(this), recipients_[i], amount);
            totalDistributed = totalDistributed.add(amount);
        }

        require(totalDistributed == INITIAL_SUPPLY, "Invalid distribution total");
        initialDistributionDone = true;
    }

    // =============================
    // View Function
    // =============================
    
    /**
     * @dev Gets the adjusted balance
     */
    /// @notice Returns the current balance of an account, adjusted by the rebase factor
    /// @dev For excluded accounts, returns the base balance without rebase adjustment
    /// @param account The address to query the balance of
    /// @return The current balance of the account
    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcludedFromRebase[account]) {
            return _baseBalances[account];
        }
        return _baseBalances[account].mul(rebaseConfig.rebaseFactor).div(1e18);
    }

    /**
     * @dev Gets the adjusted total supply
     */
    /// @notice Returns the current total supply, adjusted by the rebase factor
    /// @dev Calculates total supply based on base supply and current rebase factor
    /// @return The current total token supply
    function totalSupply() public view override returns (uint256) {
        return super.totalSupply().mul(rebaseConfig.rebaseFactor).div(1e18);
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
        uint256 baseAmount = _isExcludedFromRebase[sender]
            ? amount
            : amount.mul(1e18).div(rebaseConfig.rebaseFactor);

        // Update base balance
        _baseBalances[sender] = _baseBalances[sender].sub(baseAmount);
        _baseBalances[recipient] = _baseBalances[recipient].add(baseAmount);

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

    /// @notice Excludes or includes an account from rebase effects
    /// @dev Can only be called by the contract owner
    /// @param account_ The address to exclude or include
    /// @param excluded_ True to exclude, false to include
    function excludeFromRebase(address account_, bool excluded_) external onlyOwner {
        _isExcludedFromRebase[account_] = excluded_;
        emit ExcludedFromRebase(account_, excluded_);
    }
}