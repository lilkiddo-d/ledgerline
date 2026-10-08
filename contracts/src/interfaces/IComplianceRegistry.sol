// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Pluggable compliance hook. Returning false blocks the gated action.
interface IComplianceRegistry {
    function isAllowed(address account, uint8 action) external view returns (bool);
}
