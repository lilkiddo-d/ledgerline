// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {MathLib} from "../libraries/MathLib.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";

/// @title InterestRateModel
/// @notice Immutable kinked (jump) utilization model. Rates are annual, in RAY.
///         rate = base + slope1 * U / Uopt                          for U <= Uopt
///         rate = base + slope1 + slope2 * (U - Uopt) / (1 - Uopt)  for U >  Uopt
///         To change parameters governance deploys a new model and points AssetConfig at it.
contract InterestRateModel is IInterestRateModel {
    using MathLib for uint256;

    uint256 public immutable BASE_RATE;
    uint256 public immutable SLOPE1;
    uint256 public immutable SLOPE2;
    uint256 public immutable OPTIMAL_UTILIZATION;
    uint256 public constant MAX_RATE = 10 * MathLib.RAY; // 1000% APR hard ceiling

    constructor(uint256 baseRate, uint256 slope1, uint256 slope2, uint256 optimalUtilization) {
        if (optimalUtilization == 0 || optimalUtilization >= MathLib.RAY) revert LLErrors.InvalidParams();
        if (baseRate + slope1 + slope2 > MAX_RATE) revert LLErrors.InvalidParams();
        BASE_RATE = baseRate;
        SLOPE1 = slope1;
        SLOPE2 = slope2;
        OPTIMAL_UTILIZATION = optimalUtilization;
    }

    function utilization(uint256 cash, uint256 totalDebt) public pure returns (uint256) {
        if (totalDebt == 0) return 0;
        return totalDebt.mulDivDown(MathLib.RAY, cash + totalDebt);
    }

    function getBorrowRate(uint256 cash, uint256 totalDebt) external view returns (uint256) {
        uint256 u = utilization(cash, totalDebt);
        if (u <= OPTIMAL_UTILIZATION) {
            return BASE_RATE + SLOPE1.mulDivDown(u, OPTIMAL_UTILIZATION);
        }
        return BASE_RATE + SLOPE1 + SLOPE2.mulDivDown(u - OPTIMAL_UTILIZATION, MathLib.RAY - OPTIMAL_UTILIZATION);
    }
}
