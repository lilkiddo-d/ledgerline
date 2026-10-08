// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Types} from "../libraries/Types.sol";

interface IAssetConfig {
    function getRiskParams(address asset) external view returns (Types.RiskParams memory);
    function getEModeCategory(uint8 id) external view returns (Types.EModeCategory memory);
    function interestRateModel(address asset) external view returns (address);
}
