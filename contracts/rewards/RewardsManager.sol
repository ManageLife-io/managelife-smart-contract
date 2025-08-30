// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdminControl} from "../interfaces/IAdminControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RescueERC20Timelock} from "../governance/RescueERC20Timelock.sol";
import {IPropertyMarket} from "../interfaces/IPropertyMarket.sol";

/**
 * @title RewardsManager
 * @author ManageLife
 * @notice Manages the distribution of rewards for various activities within the ManageLife ecosystem.
 * @dev This contract holds the reward tokens, manages the reward rates, and handles the distribution logic
 * when called by authorized contracts like the PropertyMarket.
 */
contract RewardsManager is RescueERC20Timelock {
    using SafeERC20 for IERC20;

    /**
     * @notice The ERC20 token used for distributing rewards (e.g., LifeToken).
     */
    IERC20 public rewardsToken;

    /**
     * @notice The address of the PropertyMarket contract, which is authorized to trigger reward distributions.
     */
    address public propertyMarketContract;
    /**
     * @notice The rate at which sellers earn rewards per second for having an active property listing.
     */
    uint256 public listingRewardPerSecond;

    /**
     * @notice Emitted when the rewards token address is updated.
     * @param oldRewardsToken The address of the previous rewards token.
     * @param newRewardsToken The address of the new rewards token.
     */
    event RewardsTokenSet(address indexed oldRewardsToken, address indexed newRewardsToken);

    /**
     * @notice Emitted when the property market contract address is updated.
     * @param oldPropertyMarketContract The address of the previous property market contract.
     * @param newPropertyMarketContract The address of the new property market contract.
     */
    event PropertyMarketContractUpdated(
        address indexed oldPropertyMarketContract, address indexed newPropertyMarketContract
    );

    /**
     * @notice Emitted when the listing reward rate per second is updated.
     * @param oldListingRewardPerSecond The previous reward rate.
     * @param newListingRewardPerSecond The new reward rate.
     */
    event ListingRewardPerSecondSet(uint256 oldListingRewardPerSecond, uint256 newListingRewardPerSecond);
    /**
     * @notice Emitted when a reward distribution fails due to insufficient funds in the contract.
     * @param required The amount of tokens required for the distribution.
     * @param available The actual balance of reward tokens available in the contract.
     */
    event NotEnoughRewards(uint256 required, uint256 available);
    /**
     * @notice Emitted when listing rewards are successfully distributed to a user.
     * @param to The address of the recipient.
     * @param amount The amount of tokens distributed.
     */
    event ListingRewardsDistributed(address indexed to, uint256 amount);

    /**
     * @notice Emitted when the AdminControl contract is updated.
     * @param oldAdminControl The address of the previous AdminControl contract.
     * @param newAdminControl The address of the new AdminControl contract.
     */
    event AdminControlUpdated(address oldAdminControl, address newAdminControl);

    /**
     * @notice Reverts if the caller does not have the DEFAULT_ADMIN_ROLE.
     */
    error OnlyAdminCanCall();
    /**
     * @notice Reverts if the caller is not the authorized PropertyMarket contract.
     * @param caller The address of the unauthorized caller.
     * @param propertyMarketContract The expected address of the PropertyMarket contract.
     */
    error OnlyPropertyMarketContract(address caller, address propertyMarketContract);
    /**
     * @notice Reverts if the caller does not have the PROTOCOL_PARAM_MANAGER_ROLE.
     */
    error OnlyProtocolParamManagerCanCall();

    error AdminControlMismatch(address adminOnRewardsManager, address adminOnPropertyManager);

    /**
     * @notice Initializes the RewardsManager contract.
     * @param _rewardsToken The address of the ERC20 rewards token.
     * @param _adminControl The address of the AdminControl contract.
     * @param propertyMarketContractAddress The address of the PropertyMarket contract.
     */
    constructor(address _rewardsToken, IAdminControl _adminControl, address propertyMarketContractAddress)
        RescueERC20Timelock(_adminControl)
    {
        constructorChecks(_rewardsToken, _adminControl, propertyMarketContractAddress);

        rewardsToken = IERC20(_rewardsToken);
        propertyMarketContract = propertyMarketContractAddress;
        listingRewardPerSecond = 38580246913580; //based on a 18 decimal token. Equivalent to 100 tokens per month. 2_592_000 seconds in a month.
    }

    /**
     * @dev Throws if called by any account other than the admin of the AdminControl contract.
     */
    modifier onlyAdmin() {
        if (!adminControl.hasRole(adminControl.DEFAULT_ADMIN_ROLE(), msg.sender)) {
            revert OnlyAdminCanCall();
        }
        _;
    }

    /**
     * @dev Throws if called by any account that does not have the PROTOCOL_PARAM_MANAGER_ROLE.
     */
    modifier onlyProtocolParamManager() {
        if (!adminControl.hasRole(adminControl.PROTOCOL_PARAM_MANAGER_ROLE(), msg.sender)) {
            revert OnlyProtocolParamManagerCanCall();
        }
        _;
    }

    /**
     * @dev Throws if the caller is not the authorized PropertyMarket contract.
     */
    modifier onlyPropertyMarketContract() {
        if (msg.sender != propertyMarketContract) {
            revert OnlyPropertyMarketContract(msg.sender, propertyMarketContract);
        }
        _;
    }

    /**
     * @notice Modifier that checks if a function is paused in the AdminControl contract.
     * @param functionId The ID of the function to check.
     */
    modifier whenFunctionActive(bytes32 functionId) {
        adminControl.checkPaused(functionId);
        _;
    }

    /**
     * @notice Checks if a given payment token is exempt from sales fees.
     * @dev Returns true if the provided payment token address matches the rewards token address.
     * @param paymentToken The address of the payment token to check.
     * @return True if the payment token is exempt from sales fees, false otherwise.
     */
    function isExemptFromSalesFee(address paymentToken) external view returns (bool) {
        return paymentToken == address(rewardsToken);
    }

    /**
     * @notice Distributes listing rewards to a specified address.
     * @dev Can only be called by the PropertyMarket contract. If the contract has insufficient funds,
     * it emits a `NotEnoughRewards` event and returns without reverting to ensure the primary transaction (e.g., a sale) does not fail.
     * @param to The recipient of the rewards.
     * @param amount The amount of rewards to distribute.
     */
    function distributeListingRewards(address to, uint256 amount) external onlyPropertyMarketContract {
        uint256 balance = rewardsToken.balanceOf(address(this));
        if (amount > balance) {
            emit NotEnoughRewards(amount, balance);
            return;
        }
        rewardsToken.safeTransfer(to, amount);
        emit ListingRewardsDistributed(to, amount);
    }

    /**
     * @notice Sets a new rewards token for the RewardsManager contract.
     * @dev Only callable by an admin when the protocol wiring configuration is active.
     * Emits a {RewardsTokenSet} event indicating the old and new rewards token addresses.
     * @param _rewardsToken The address of the new rewards token (ERC20).
     */
    function setRewardsToken(address _rewardsToken)
        external
        onlyAdmin
        whenFunctionActive(adminControl.PROTOCOL_WIRING_CONFIGURATION())
    {
        if (_rewardsToken == address(0)) {
            revert ZeroAddress();
        }
        address oldRewardsToken = address(rewardsToken);
        rewardsToken = IERC20(_rewardsToken);
        emit RewardsTokenSet(oldRewardsToken, _rewardsToken);
    }

    /**
     * @notice Sets the property market contract address.
     * @dev Can only be called by an account with the DEFAULT_ADMIN_ROLE.
     * @param _propertyMarketContract The new property market contract address.
     */
    function setPropertyMarketContract(address _propertyMarketContract)
        external
        onlyAdmin
        whenFunctionActive(adminControl.PROTOCOL_WIRING_CONFIGURATION())
    {
        if (_propertyMarketContract == address(0)) {
            revert ZeroAddress();
        }
        IAdminControl rewardsManagerAdminControl = adminControl;
        IAdminControl adminOnPropertyManager = IPropertyMarket(_propertyMarketContract).adminControl();
        if (address(adminOnPropertyManager) != address(rewardsManagerAdminControl)) {
            revert AdminControlMismatch(address(rewardsManagerAdminControl), address(adminOnPropertyManager));
        }
        address oldPropertyMarketContract = propertyMarketContract;
        propertyMarketContract = _propertyMarketContract;
        emit PropertyMarketContractUpdated(oldPropertyMarketContract, _propertyMarketContract);
    }

    /**
     * @notice Sets the rate for listing rewards per second.
     * @dev Can only be called by an account with the PROTOCOL_PARAM_MANAGER_ROLE.
     * @param _listingRewardPerSecond The new reward rate per second.
     */
    function setListingRewardPerSecond(uint256 _listingRewardPerSecond)
        external
        onlyProtocolParamManager
        whenFunctionActive(adminControl.PROTOCOL_PARAM_CONFIGURATION())
    {
        uint256 oldListingRewardPerSecond = listingRewardPerSecond;
        listingRewardPerSecond = _listingRewardPerSecond;
        emit ListingRewardPerSecondSet(oldListingRewardPerSecond, _listingRewardPerSecond);
    }

    function setAdminControl(IAdminControl _adminControl)
        external
        onlyAdmin
        whenFunctionActive(adminControl.PROTOCOL_WIRING_CONFIGURATION())
    {
        if (address(_adminControl) == address(0)) {
            revert ZeroAddress();
        }
        address oldAdminControl = address(adminControl);
        address adminOnPropertyManager = address(IPropertyMarket(propertyMarketContract).adminControl());
        if (adminOnPropertyManager != address(_adminControl)) {
            revert AdminControlMismatch(address(_adminControl), adminOnPropertyManager);
        }
        adminControl = _adminControl;
        emit AdminControlUpdated(oldAdminControl, address(_adminControl));
    }

    /**
     * @notice Returns the current balance of the rewards pool.
     * @dev This function returns the amount of rewards tokens held by this contract.
     * @return The balance of the rewards token in this contract.
     */
    function getRewardPoolBalance() external view returns (uint256) {
        return rewardsToken.balanceOf(address(this));
    }

    function constructorChecks(
        address _rewardsToken,
        IAdminControl _adminControl,
        address propertyMarketContractAddress
    ) internal view {
        if (_rewardsToken == address(0)) {
            revert ZeroAddress();
        }
        if (propertyMarketContractAddress == address(0)) {
            revert ZeroAddress();
        }

        IAdminControl adminOnPropertyManager = IPropertyMarket(propertyMarketContractAddress).adminControl();
        if (address(adminOnPropertyManager) != address(_adminControl)) {
            revert AdminControlMismatch(address(_adminControl), address(adminOnPropertyManager));
        }
    }
}
