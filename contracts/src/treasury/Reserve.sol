// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IReserve} from "../interfaces/IReserve.sol";

/// @title Reserve
/// @notice Bad-debt backstop. Funded by a share of protocol revenue (via FeeCollector). When an
///         account is left with debt and no collateral, the Pool pulls up to the outstanding amount
///         from here before socializing any remainder across suppliers.
contract Reserve is IReserve, AccessControl {
    using SafeERC20 for IERC20;

    address public immutable POOL;

    event BadDebtCovered(address indexed asset, uint256 amount);
    event ReserveWithdrawn(address indexed asset, address indexed to, uint256 amount);

    constructor(address admin, address pool) {
        if (admin == address(0) || pool == address(0)) revert LLErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        POOL = pool;
    }

    /// @inheritdoc IReserve
    function coverBadDebt(address asset, uint256 amount) external returns (uint256 covered) {
        if (msg.sender != POOL) revert LLErrors.OnlyPool();
        uint256 bal = IERC20(asset).balanceOf(address(this));
        covered = amount < bal ? amount : bal;
        if (covered == 0) return 0;
        emit BadDebtCovered(asset, covered);
        IERC20(asset).safeTransfer(POOL, covered);
    }

    /// @notice Governance (Timelock) can redeploy excess reserves.
    function withdraw(address asset, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert LLErrors.ZeroAddress();
        emit ReserveWithdrawn(asset, to, amount);
        IERC20(asset).safeTransfer(to, amount);
    }
}
