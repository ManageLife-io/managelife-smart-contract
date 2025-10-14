// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IAdminControl} from "./IAdminControl.sol";
import {IManageLifePropertyNFT} from "./IManageLifePropertyNFT.sol";

interface IManageLifePropertyNFTController {
    function adminController() external view returns (IAdminControl);
    function manageLifePropertiesNftContract() external view returns (IManageLifePropertyNFT);
}

