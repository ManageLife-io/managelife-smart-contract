// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
//TODO: //- I THINK THE SOME OF THE ADMIN FUNCTION SPECIALLY THE WIRING FUNCTIONS ALSO NEED A TIMELOCK

/// @title AdminControl - Core contract for system administration and configuration
/// @notice Manages system roles, fees, KYC verification, and reward parameters
/// @dev Implements role-based access control and emergency pause functionality
contract AdminControl is AccessControl, Pausable {
    // Rename these events to avoid conflicts with AccessControl contract events
    event AdminRoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event AdminRoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    using EnumerableSet for EnumerableSet.AddressSet;

    error GlobalPause();
    error FunctionPaused(bytes32 functionId);
    error ZeroAddress();
    error ExceedsMaxFee(uint256 maxFee);

    // ============ Function IDs for Pausing ==========

    //This one pauses all protocol parameter configuration functions
    bytes32 public constant PROTOCOL_PARAM_CONFIGURATION = keccak256("PROTOCOL_PARAM_CONFIGURATION");
    //This one pauses all protocol wiring functions (Linking one contract to another post deployment)
    bytes32 public constant PROTOCOL_WIRING_CONFIGURATION = keccak256("PROTOCOL_WIRING_CONFIGURATION");
    //This one pauses all kyc configuration functions
    bytes32 public constant KYC_CONFIGURATION = keccak256("KYC_CONFIGURATION");

    // ========== Role Definitions ==========
    bytes32 public constant PROTOCOL_PARAM_MANAGER_ROLE = keccak256("PROTOCOL_PARAM_MANAGER_ROLE");
    bytes32 public constant PROTOCOL_PARAM_TIMELOCKED_MANAGER_ROLE = keccak256("PROTOCOL_PARAM_TIMELOCKED_MANAGER_ROLE");

    bytes32 public constant KYC_ROLE = keccak256("KYC_ROLE");
    bytes32 public constant NFT_PROPERTY_MANAGER_ROLE = keccak256("NFT_PROPERTY_MANAGER_ROLE");
    bytes32 public constant TOKEN_WHITELIST_MANAGER_ROLE = keccak256("TOKEN_WHITELIST_MANAGER_ROLE");
    bytes32 public constant ERC20_RESCUE_ROLE = keccak256("ERC20_RESCUE_ROLE");

    // ========== Constants ==========
    uint256 public constant BASIS_POINTS = 10000; // Base for percentage calculations (100% = 10000, 1% = 100)

    // ========== Fee Structure ==========
    struct FeeSettings {
        uint256 baseFee; // Base transaction fee rate (basis points: 100 = 1%)
        uint256 maxFee; // Maximum allowed fee rate (basis points)
        address feeCollector; // Fee collection address
    }

    // ========== Reward Parameters Structure ==========
    struct RewardParameters {
        uint256 baseRate; // Base reward rate (basis points)
        uint256 communityMultiplier; // Community bonus multiplier
        uint256 maxLeaseBonus; // Maximum lease duration bonus
        address rewardsVault; // Rewards vault address
    }

    // ========== State Variables ==========
    FeeSettings public feeConfig;
    RewardParameters public rewardParams;

    EnumerableSet.AddressSet private _kycVerified;
    mapping(bytes32 => bool) public functionPaused;

    /// @notice The minimum delay (in seconds) before ERC20 rescue operations can be executed.
    /// @dev This is set to ensure that funds cannot be withdrawn prematurely, protecting users during ongoing sales.
    uint256 public erc20RescueDelay;

    // ========== Event Definitions ==========
    event FeeConfigUpdated(
        uint256 oldBaseFee, uint256 newBaseFee, uint256 oldMaxFee, uint256 newMaxFee, address indexed admin
    );
    event KYCStatusUpdated(address indexed account, bool approved);
    event Erc20RescueDelayUpdated(uint256 oldDelay, uint256 newDelay, address indexed admin);

    function _initializeRoles(address admin, address timelockContractAddress) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROTOCOL_PARAM_MANAGER_ROLE, admin);
        _grantRole(PROTOCOL_PARAM_TIMELOCKED_MANAGER_ROLE, timelockContractAddress);
        _grantRole(KYC_ROLE, admin);
        _grantRole(NFT_PROPERTY_MANAGER_ROLE, admin);
        _grantRole(TOKEN_WHITELIST_MANAGER_ROLE, admin);
        _grantRole(ERC20_RESCUE_ROLE, admin);
    }

    /// @notice Initializes the AdminControl contract with the given parameters.
    /// @param initialAdmin The address of the initial admin.
    /// @param feeCollector The address of the fee collector.
    /// @param timelockContractAddress The address of the timelock contract. (Make sure this is the actual timelock contract address, not the admin address)
    constructor(address initialAdmin, address feeCollector, address timelockContractAddress) {
        if (feeCollector == address(0)) {
            revert ZeroAddress();
        }
        if (initialAdmin == address(0)) {
            revert ZeroAddress();
        }

        // Initialize role assignments
        _initializeRoles(initialAdmin, timelockContractAddress);

        // Initialize fee configuration
        feeConfig = FeeSettings({
            baseFee: 200, // 2%
            maxFee: 1000, // 10%
            feeCollector: feeCollector
        });

        erc20RescueDelay = 14 days; //defaults to 14 days, long enough for all sales to finish.
    }

    /// @notice Modifier that checks if a function is paused.
    /// @param functionId The ID of the function to check.
    modifier whenFunctionActive(bytes32 functionId) {
        checkPaused(functionId);
        _;
    }

    // ========== Fee Management ==========
    /// @notice Updates the fee configuration for the propertyMarket Contract
    /// @dev Only callable by accounts with PROTOCOL_PARAM_TIMELOCKED_MANAGER_ROLE
    /// @param newBaseFee New base fee rate in basis points (100 = 1%)
    /// @param newCollector New address to collect fees
    function updateFeeConfig(uint256 newBaseFee, address newCollector)
        external
        onlyRole(PROTOCOL_PARAM_TIMELOCKED_MANAGER_ROLE)
        whenFunctionActive(PROTOCOL_PARAM_CONFIGURATION)
    {
        if (newCollector == address(0)) {
            revert ZeroAddress();
        }
        if (newBaseFee > feeConfig.maxFee) {
            revert ExceedsMaxFee(feeConfig.maxFee);
        }

        uint256 oldBase = feeConfig.baseFee;
        uint256 oldMax = feeConfig.maxFee;

        feeConfig.baseFee = newBaseFee;
        feeConfig.feeCollector = newCollector;

        emit FeeConfigUpdated(oldBase, newBaseFee, oldMax, feeConfig.maxFee, msg.sender);
    }

    /// @notice Updates the delay for the erc20 rescue function in the propertyMarket contract
    /// @dev Only callable by accounts with PROTOCOL_PARAM_TIMELOCKED_MANAGER_ROLE
    /// @param newDelay New delay in seconds
    function updateErc20RescueDelay(uint256 newDelay)
        external
        onlyRole(PROTOCOL_PARAM_TIMELOCKED_MANAGER_ROLE)
        whenFunctionActive(PROTOCOL_PARAM_CONFIGURATION)
    {
        uint256 oldDelay = erc20RescueDelay;
        erc20RescueDelay = newDelay;
        emit Erc20RescueDelayUpdated(oldDelay, newDelay, msg.sender);
    }

    // ========== KYC Management ==========
    /// @notice Batch approves or revokes KYC verification for multiple accounts
    /// @dev Only callable by accounts with LEGAL_ROLE
    /// @param accounts Array of addresses to update KYC status
    /// @param approved True to approve, false to revoke KYC status
    function batchApproveKYC(address[] calldata accounts, bool approved)
        external
        onlyRole(KYC_ROLE)
        whenFunctionActive(KYC_CONFIGURATION)
    {
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length;) {
            address account = accounts[i];
            if (approved) {
                _kycVerified.add(account);
            } else {
                _kycVerified.remove(account);
            }
            emit KYCStatusUpdated(account, approved);
            unchecked {
                ++i;
            }
        }
    }

    // ========== Emergency Controls ==========
    /// @notice Pauses or unpauses a specific function in emergency situations
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    /// @param functionId ID of the function to pause/unpause
    /// @param paused True to pause, false to unpause
    function setFunctionPausedStatus(bytes32 functionId, bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        functionPaused[functionId] = paused;
    }

    /// @notice Pauses all contract operations in emergency situations
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    function globalPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resumes all contract operations after emergency pause
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    function globalUnpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Checks if an account is KYC verified
    /// @param account Address to check KYC status
    /// @return True if account is KYC verified
    function isKYCVerified(address account) external view returns (bool) {
        return _kycVerified.contains(account);
    }

    /// @notice Checks if a function or the entire contract is paused.
    /// @dev Reverts with GlobalPause() if globally paused, or FunctionPaused(functionId) if the specific function is paused.
    /// @param functionId ID of the function to check.
    function checkPaused(bytes32 functionId) public view {
        if (paused()) {
            revert GlobalPause();
        }
        if (functionPaused[functionId]) {
            revert FunctionPaused(functionId);
        }
    }
}
