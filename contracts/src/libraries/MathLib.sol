// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MathLib
/// @notice Fixed-point helpers. Indices are RAY (1e27), prices are WAD (1e18), risk params are BPS (1e4).
/// @dev Every helper names its rounding direction explicitly so callers always round in the protocol's favour.
library MathLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    function rayMulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, RAY);
    }

    function rayMulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, RAY, Math.Rounding.Ceil);
    }

    function rayDivDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, RAY, b);
    }

    function rayDivUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, RAY, b, Math.Rounding.Ceil);
    }

    function bpsMulDown(uint256 a, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(a, bps, BPS);
    }

    function bpsMulUp(uint256 a, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(a, bps, BPS, Math.Rounding.Ceil);
    }

    function mulDivDown(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return Math.mulDiv(a, b, c);
    }

    function mulDivUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return Math.mulDiv(a, b, c, Math.Rounding.Ceil);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
