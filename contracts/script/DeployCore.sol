// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Pool} from "../src/core/Pool.sol";
import {AssetConfig} from "../src/core/AssetConfig.sol";
import {LiquidationLogic} from "../src/core/LiquidationLogic.sol";
import {FlashLoan} from "../src/core/FlashLoan.sol";
import {InterestRateModel} from "../src/core/InterestRateModel.sol";
import {ReceiptToken} from "../src/core/ReceiptToken.sol";
import {DebtToken} from "../src/core/DebtToken.sol";
import {MarketClock} from "../src/risk/MarketClock.sol";
import {OracleAdapter} from "../src/risk/OracleAdapter.sol";
import {Reserve} from "../src/treasury/Reserve.sol";
import {FeeCollector} from "../src/treasury/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/token/ProjectTokenHooks.sol";
import {Timelock} from "../src/governance/Timelock.sol";
import {ComplianceRegistry} from "../src/compliance/ComplianceRegistry.sol";
import {PoolLens} from "../src/periphery/PoolLens.sol";
import {Types} from "../src/libraries/Types.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IMarketClock} from "../src/interfaces/IMarketClock.sol";
import {IComplianceRegistry} from "../src/interfaces/IComplianceRegistry.sol";
import {IReserve} from "../src/interfaces/IReserve.sol";
import {IProjectTokenHooks} from "../src/interfaces/IProjectTokenHooks.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";

/// @notice Deployment + wiring logic shared by script/Deploy.s.sol and the test suite, so tests
///         exercise exactly what ships.
abstract contract DeployCore {
    struct Config {
        address deployer; // temporary admin during wiring; renounced in _handover
        address governance; // Timelock proposer/executor (multisig recommended)
        address guardian; // instant pause / freeze
        address treasury;
        address keeper; // FeeCollector swaps
        address stablecoin;
        uint256 timelockDelay;
    }

    struct AssetSpec {
        address asset;
        address feed;
        bool stock;
        Types.RiskParams params;
    }

    struct Deployment {
        Timelock timelock;
        Pool pool;
        AssetConfig assetConfig;
        LiquidationLogic liquidationLogic;
        FlashLoan flashLoanModule;
        MarketClock clock;
        OracleAdapter oracle;
        ComplianceRegistry compliance;
        Reserve reserve;
        FeeCollector feeCollector;
        ProjectTokenHooks hooks;
        PoolLens lens;
        InterestRateModel stableIrm;
        InterestRateModel stockIrm;
    }

    uint256 internal constant RAY = 1e27;

    function _deployCore(Config memory c) internal returns (Deployment memory d) {
        address[] memory gov = new address[](1);
        gov[0] = c.governance;
        d.timelock = new Timelock(c.timelockDelay, gov, gov);

        d.assetConfig = new AssetConfig(c.deployer);
        d.liquidationLogic = new LiquidationLogic();
        d.flashLoanModule = new FlashLoan();
        d.pool = new Pool(c.deployer, c.guardian, d.assetConfig, address(d.liquidationLogic), address(d.flashLoanModule));
        d.assetConfig.setPool(address(d.pool));

        d.clock = new MarketClock(c.deployer, c.guardian);
        _seedHolidays(d.clock);
        d.oracle = new OracleAdapter(c.deployer, IMarketClock(address(d.clock)));
        d.compliance = new ComplianceRegistry(c.deployer, c.governance); // disabled by default
        d.reserve = new Reserve(address(d.timelock), address(d.pool));
        d.feeCollector =
            new FeeCollector(c.deployer, IPool(address(d.pool)), c.stablecoin, address(d.reserve), c.treasury, IPriceOracle(address(d.oracle)));
        d.hooks = new ProjectTokenHooks(address(d.timelock), IERC20(c.stablecoin), address(d.feeCollector));
        d.lens = new PoolLens(IPool(address(d.pool)));

        d.pool.setOracle(IPriceOracle(address(d.oracle)));
        d.pool.setMarketClock(IMarketClock(address(d.clock)));
        d.pool.setCompliance(IComplianceRegistry(address(d.compliance)));
        d.pool.setReserve(IReserve(address(d.reserve)));
        d.pool.setFeeCollector(address(d.feeCollector));
        d.pool.setProjectTokenHooks(IProjectTokenHooks(address(d.hooks)));
        d.feeCollector.setConfig(
            address(d.reserve), c.treasury, IProjectTokenHooks(address(d.hooks)), ISwapAdapter(address(0)), IPriceOracle(address(d.oracle))
        );

        // Stablecoin: 0% base, 6% at 90% kink, steep 60% above.
        d.stableIrm = new InterestRateModel(0, (6 * RAY) / 100, (60 * RAY) / 100, (90 * RAY) / 100);
        // Stock tokens (borrowing = shorting): 2% base, 10% at 50% kink, 150% above.
        d.stockIrm = new InterestRateModel((2 * RAY) / 100, (10 * RAY) / 100, (150 * RAY) / 100, (50 * RAY) / 100);

        // E-mode 1: large-cap US tech basket.
        d.assetConfig.setEModeCategory(1, 7_500, 8_000, 500, "US Tech");
    }

    function _listAsset(Deployment memory d, AssetSpec memory s) internal {
        IERC20Metadata t = IERC20Metadata(s.asset);
        string memory sym = t.symbol();
        ReceiptToken rt = new ReceiptToken(
            IPool(address(d.pool)), d.assetConfig, s.asset, string.concat("Ledgerline ", sym), string.concat("ll", sym)
        );
        DebtToken dt = new DebtToken(
            IPool(address(d.pool)), s.asset, t.decimals(), string.concat("Ledgerline Debt ", sym), string.concat("lld", sym)
        );
        d.oracle.setFeed(
            s.asset,
            OracleAdapter.FeedConfig({
                primary: s.feed,
                secondary: address(0),
                maxAgeOpen: 25 hours,
                maxAgeClosed: s.stock ? 4 days : 25 hours,
                maxDeviationBps: 0,
                checkTokenOraclePause: s.stock,
                minPrice: s.stock ? 0.01e18 : 0.5e18,
                maxPrice: s.stock ? 0 : 2e18
            })
        );
        d.assetConfig.listAsset(s.asset, address(rt), address(dt), address(s.stock ? d.stockIrm : d.stableIrm), s.params);
    }

    /// @notice Transfers every admin role to the Timelock and renounces the deployer's roles.
    function _handover(Deployment memory d, Config memory c) internal {
        address tl = address(d.timelock);
        bytes32 admin = 0x00;

        d.pool.grantRole(admin, tl);
        d.pool.renounceRole(admin, c.deployer);

        d.assetConfig.grantRole(d.assetConfig.RISK_ADMIN_ROLE(), tl);
        d.assetConfig.grantRole(admin, tl);
        d.assetConfig.renounceRole(d.assetConfig.RISK_ADMIN_ROLE(), c.deployer);
        d.assetConfig.renounceRole(admin, c.deployer);

        d.clock.grantRole(d.clock.CLOCK_ADMIN_ROLE(), tl);
        d.clock.grantRole(admin, tl);
        d.clock.renounceRole(d.clock.CLOCK_ADMIN_ROLE(), c.deployer);
        d.clock.renounceRole(admin, c.deployer);

        d.oracle.grantRole(d.oracle.ORACLE_ADMIN_ROLE(), tl);
        d.oracle.grantRole(admin, tl);
        d.oracle.renounceRole(d.oracle.ORACLE_ADMIN_ROLE(), c.deployer);
        d.oracle.renounceRole(admin, c.deployer);

        d.compliance.grantRole(admin, tl);
        d.compliance.renounceRole(admin, c.deployer);

        d.feeCollector.grantRole(d.feeCollector.KEEPER_ROLE(), c.keeper);
        d.feeCollector.grantRole(admin, tl);
        if (c.keeper != c.deployer) d.feeCollector.renounceRole(d.feeCollector.KEEPER_ROLE(), c.deployer);
        d.feeCollector.renounceRole(admin, c.deployer);
    }

    /// @dev NYSE full-day holidays and 13:00 early closes, 2026-2027 (local New York dates).
    function _seedHolidays(MarketClock clock) internal {
        uint32[] memory h = new uint32[](20);
        h[0] = 20260101;
        h[1] = 20260119;
        h[2] = 20260216;
        h[3] = 20260403;
        h[4] = 20260525;
        h[5] = 20260619;
        h[6] = 20260703;
        h[7] = 20260907;
        h[8] = 20261126;
        h[9] = 20261225;
        h[10] = 20270101;
        h[11] = 20270118;
        h[12] = 20270215;
        h[13] = 20270326;
        h[14] = 20270531;
        h[15] = 20270618;
        h[16] = 20270705;
        h[17] = 20270906;
        h[18] = 20271125;
        h[19] = 20271224;
        clock.setHolidays(h, true);
        clock.setEarlyClose(20261127, 780);
        clock.setEarlyClose(20261224, 780);
        clock.setEarlyClose(20271126, 780);
    }

    // ---------------- default risk parameters ----------------

    function _stableParams(uint128 supplyCap, uint128 borrowCap) internal pure returns (Types.RiskParams memory p) {
        p = Types.RiskParams({
            ltvBps: 8_000,
            liqThresholdBps: 8_500,
            liqBonusBps: 500,
            closedLtvBps: 8_000,
            reserveFactorBps: 1_000,
            liqProtocolFeeBps: 1_000,
            eModeCategory: 0,
            isStock: false,
            collateralEnabled: true,
            borrowEnabled: true,
            supplyCap: supplyCap,
            borrowCap: borrowCap,
            closedBorrowCap: 0
        });
    }

    /// @param tier 0 = index ETF, 1 = large-cap tech (e-mode), 2 = high volatility
    function _stockParams(uint8 tier, uint128 supplyCap, uint128 borrowCap) internal pure returns (Types.RiskParams memory p) {
        p.isStock = true;
        p.collateralEnabled = true;
        p.borrowEnabled = true;
        p.reserveFactorBps = 2_000;
        p.liqProtocolFeeBps = 1_000;
        p.supplyCap = supplyCap;
        p.borrowCap = borrowCap;
        p.closedBorrowCap = borrowCap / 5;
        if (tier == 0) {
            (p.ltvBps, p.liqThresholdBps, p.liqBonusBps, p.closedLtvBps) = (7_000, 7_800, 600, 5_000);
        } else if (tier == 1) {
            (p.ltvBps, p.liqThresholdBps, p.liqBonusBps, p.closedLtvBps) = (6_000, 7_000, 800, 4_000);
            p.eModeCategory = 1;
        } else {
            (p.ltvBps, p.liqThresholdBps, p.liqBonusBps, p.closedLtvBps) = (5_000, 6_000, 1_000, 3_000);
        }
    }
}
