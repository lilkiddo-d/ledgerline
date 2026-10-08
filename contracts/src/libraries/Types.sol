// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Shared data structures.
library Types {
    /// @notice Per-asset risk parameters, owned by AssetConfig.
    struct RiskParams {
        uint16 ltvBps; // max borrow power per unit of collateral value
        uint16 liqThresholdBps; // collateral weight in the health factor
        uint16 liqBonusBps; // extra collateral paid to liquidators, e.g. 500 = 5%
        uint16 closedLtvBps; // LTV cap while the US equity market is closed (stocks only)
        uint16 reserveFactorBps; // share of interest routed to the protocol
        uint16 liqProtocolFeeBps; // share of the liquidation bonus routed to the protocol
        uint8 eModeCategory; // 0 = none
        bool isStock;
        bool collateralEnabled;
        bool borrowEnabled;
        uint128 supplyCap; // in underlying units, 0 = uncapped
        uint128 borrowCap; // in underlying units, 0 = uncapped
        uint128 closedBorrowCap; // max total debt while market closed (stocks only), 0 = no new borrows
    }

    /// @notice E-mode category for correlated assets.
    struct EModeCategory {
        uint16 ltvBps;
        uint16 liqThresholdBps;
        uint16 liqBonusBps;
        string label;
    }

    /// @notice Pool-side mutable state for one listed asset.
    struct ReserveData {
        uint128 liquidityIndex; // RAY, value of one receipt share in underlying
        uint128 borrowIndex; // RAY, value of one debt share in underlying
        uint128 cash; // internally tracked liquidity (donations are ignored)
        uint128 accruedToTreasuryScaled; // receipt shares owed to the FeeCollector, not yet minted
        uint128 borrowRateRay; // current annual borrow rate (RAY)
        uint40 lastUpdate;
        uint8 id;
        bool active;
        bool frozen; // no new supply / borrow
        bool paused; // no actions at all
        address receiptToken;
        address debtToken;
    }

    /// @notice Aggregated account view (USD values in WAD).
    struct AccountData {
        uint256 collateralUsd;
        uint256 debtUsd;
        uint256 borrowPowerUsd; // sum(collateral * effective LTV)
        uint256 weightedThresholdUsd; // sum(collateral * effective liquidation threshold)
        uint256 healthFactor; // WAD, type(uint256).max when there is no debt
    }

    // Compliance action identifiers.
    uint8 internal constant ACTION_SUPPLY = 1;
    uint8 internal constant ACTION_BORROW = 2;
    uint8 internal constant ACTION_FLASHLOAN = 3;
    uint8 internal constant ACTION_RECEIVE_TRANSFER = 4;
}
