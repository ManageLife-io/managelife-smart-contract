//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdminControl} from "../interfaces/IAdminControl.sol";

//TODO: add erc20 recovery contract to this.
contract RewardsManager {
    IERC20 public rewardsToken;//LifeToken
    IAdminControl public immutable adminControl;

    event RewardsTokenSet(address indexed oldRewardsToken,address indexed newRewardsToken);

    error NotEnoughRewards(uint256 required,uint256 available);
    error OnlyAdminCanCall();

    constructor(address _rewardsToken,IAdminControl _adminControl) {
        rewardsToken = IERC20(_rewardsToken);
        adminControl = _adminControl;
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
     * @notice Sets a new rewards token for the RewardsManager contract.
     * @dev Only callable by an admin when the protocol wiring configuration is active.
     * Emits a {RewardsTokenSet} event indicating the old and new rewards token addresses.
     * @param _rewardsToken The address of the new rewards token (ERC20).
     */
    function setRewardsToken(address _rewardsToken) external onlyAdmin whenFunctionActive(adminControl.PROTOCOL_WIRING_CONFIGURATION()) {
        address oldRewardsToken = address(rewardsToken);
        rewardsToken = IERC20(_rewardsToken);
        emit RewardsTokenSet(oldRewardsToken,_rewardsToken);
    }

    /**
     * @notice Returns the current balance of the rewards pool.
     * @dev This function returns the amount of rewards tokens held by this contract.
     * @return The balance of the rewards token in this contract.
     */
    function getRewardPoolBalance() external view returns (uint256) {
        return rewardsToken.balanceOf(address(this));
    }


}

