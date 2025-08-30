//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdminControl} from "./IAdminControl.sol";

interface IRewardsManager {
    function rewardsToken() external view returns (IERC20);

    function adminControl() external view returns (IAdminControl);

    function propertyMarketContract() external view returns (address);

    /**
     * @notice Checks if a given payment token is exempt from sales fees.
     * @param paymentToken The address of the payment token to check.
     * @return True if the payment token is exempt from sales fees, false otherwise.
     */
    function isExemptFromSalesFee(address paymentToken) external view returns (bool);

    /**
     * @notice Distributes listing rewards to a specified address.
     * @param to The recipient of the rewards.
     * @param amount The amount of rewards to distribute.
     */
    function distributeListingRewards(address to, uint256 amount) external;

    /**
     * @notice Returns the current reward rate per second for listings.
     * @return The amount of rewards distributed per second for listings.
     */
    function listingRewardPerSecond() external view returns (uint256);
}
