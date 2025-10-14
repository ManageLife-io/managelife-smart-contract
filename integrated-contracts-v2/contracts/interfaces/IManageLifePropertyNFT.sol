// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import {IAdminControl} from "./IAdminControl.sol";
interface IManageLifePropertyNFT {
    function mintPropertyNFT(address to, bool deedHeldAtManageLife) external returns (uint256);
    function setDeedHeldAtManageLife(uint256 tokenId, bool deedHeldAtManageLife) external;
    function propertyControllerContract() external view returns (address);
    function adminController() external view returns (IAdminControl);
}