// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IMarketClock {
    function isMarketOpen() external view returns (bool);
}
