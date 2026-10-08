// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist gate, OFF by default. When enabled, only allowlisted accounts can
///         supply, borrow, take flash loans or receive receipt-token transfers. Repay, withdraw and
///         liquidations are never gated, so users can always exit and the protocol stays solvent.
///         Turning the gate on/off is a Timelock action; day-to-day allowlist edits use
///         ALLOWLIST_MANAGER_ROLE (an operator chosen by governance).
contract ComplianceRegistry is IComplianceRegistry, AccessControl {
    bytes32 public constant ALLOWLIST_MANAGER_ROLE = keccak256("ALLOWLIST_MANAGER_ROLE");
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address => bool) public allowed;

    event EnabledSet(bool enabled);
    event AllowedSet(address indexed account, bool allowed);

    constructor(address admin, address manager) {
        if (admin == address(0) || manager == address(0)) revert LLErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ALLOWLIST_MANAGER_ROLE, manager);
    }

    function setEnabled(bool on) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = on;
        emit EnabledSet(on);
    }

    function setAllowed(address[] calldata accounts, bool isAllowed_) external onlyRole(ALLOWLIST_MANAGER_ROLE) {
        if (accounts.length > MAX_BATCH) revert LLErrors.InvalidParams();
        for (uint256 i; i < accounts.length; ++i) {
            allowed[accounts[i]] = isAllowed_;
            emit AllowedSet(accounts[i], isAllowed_);
        }
    }

    /// @inheritdoc IComplianceRegistry
    function isAllowed(address account, uint8) external view returns (bool) {
        return !enabled || allowed[account];
    }
}
