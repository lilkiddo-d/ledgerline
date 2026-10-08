// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IProjectTokenHooks {
    function isActive() external view returns (bool);
    /// @return discount in BPS applied to the protocol (reserve-factor) share of a borrower's interest
    function borrowDiscountBps(address account) external view returns (uint256);
    function notifyReward(uint256 amount) external;
}
