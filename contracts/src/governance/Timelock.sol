// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {LLErrors} from "../libraries/LLErrors.sol";

/// @title Timelock
/// @notice Holds every admin role in the protocol. Enforces a minimum 48h delay on all governance
///         actions. Self-administered (no separate admin), so the delay can only be changed through
///         a delayed proposal, and never below 48h.
contract Timelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert LLErrors.InvalidParams();
    }

    /// @dev Even if a delayed proposal lowers the stored delay, scheduling never accepts < 48h.
    function getMinDelay() public view override returns (uint256) {
        uint256 d = super.getMinDelay();
        return d < MIN_DELAY_FLOOR ? MIN_DELAY_FLOOR : d;
    }
}
