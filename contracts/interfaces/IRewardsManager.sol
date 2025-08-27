//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdminControl} from "./IAdminControl.sol";

interface IRewardsManager {
    function rewardsToken() external view returns (IERC20);

    function adminControl() external view returns (IAdminControl);

    function isExemptFromSalesFee(address paymentToken) external view returns (bool);
}
