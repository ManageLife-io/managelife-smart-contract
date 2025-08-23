// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IAdminControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function NFT_PROPERTY_MANAGER_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function PROTOCOL_PARAM_MANAGER_ROLE() external view returns (bytes32);
    function TOKEN_WHITELIST_MANAGER_ROLE() external view returns (bytes32);
    function ERC20_RESCUE_ROLE() external view returns (bytes32);
    function KYC_ROLE() external view returns (bytes32);
    function isKYCVerified(address account) external view returns (bool);
    function feeConfig() external view returns (uint256 baseFee, uint256 maxFee, address feeCollector);
    function erc20RescueDelay() external view returns (uint256);
    function checkPaused(bytes32 functionId) external view;
}