// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IInterestRateModel {
    /// @return annual borrow rate in RAY
    function getBorrowRate(uint256 cash, uint256 totalDebt) external view returns (uint256);
}
