// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IAdminControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function NFT_PROPERTY_MANAGER_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
}