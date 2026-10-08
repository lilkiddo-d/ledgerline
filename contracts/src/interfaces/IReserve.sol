// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IReserve {
    /// @notice Sends up to `amount` of `asset` to the pool to cover bad debt.
    function coverBadDebt(address asset, uint256 amount) external returns (uint256 covered);
}
