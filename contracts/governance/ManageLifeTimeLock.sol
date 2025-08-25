//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
    
contract ManageLifeTimeLock is TimelockController {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address optionalAdmin
    ) TimelockController(minDelay, proposers, executors, optionalAdmin) {}
}
