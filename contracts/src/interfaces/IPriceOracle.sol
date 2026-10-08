// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Swappable price source used by the Pool. Prices are USD per whole token, scaled to 1e18.
interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256 priceWad);
}
