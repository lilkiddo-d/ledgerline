// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployCore} from "../script/DeployCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {Types} from "../src/libraries/Types.sol";
import {ReceiptToken} from "../src/core/ReceiptToken.sol";
import {DebtToken} from "../src/core/DebtToken.sol";

abstract contract BaseTest is Test, DeployCore {
    // Wed 2026-10-07 15:00 UTC = 11:00 New York (EDT) -> market open
    uint256 internal constant OPEN_TS = 1791385200;
    // Sat 2026-10-10 15:00 UTC -> market closed
    uint256 internal constant WEEKEND_TS = 1791644400;

    Deployment internal d;
    Config internal cfg;

    MockERC20 internal usdg;
    MockERC20 internal aapl;
    MockERC20 internal nvda;
    MockERC20 internal tsla;
    MockAggregator internal usdgFeed;
    MockAggregator internal aaplFeed;
    MockAggregator internal nvdaFeed;
    MockAggregator internal tslaFeed;

    address internal gov = makeAddr("gov");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public virtual {
        vm.warp(OPEN_TS);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        aapl = new MockERC20("Apple Token", "AAPL", 18);
        nvda = new MockERC20("NVIDIA Token", "NVDA", 18);
        tsla = new MockERC20("Tesla Token", "TSLA", 18);
        usdgFeed = new MockAggregator(8, 1e8);
        aaplFeed = new MockAggregator(8, 200e8);
        nvdaFeed = new MockAggregator(8, 100e8);
        tslaFeed = new MockAggregator(8, 250e8);

        cfg = Config({
            deployer: address(this),
            governance: gov,
            guardian: guardian,
            treasury: treasury,
            keeper: keeper,
            stablecoin: address(usdg),
            timelockDelay: 48 hours
        });
        d = _deployCore(cfg);
        _listAsset(d, AssetSpec(address(usdg), address(usdgFeed), false, _stableParams(0, 0)));
        _listAsset(d, AssetSpec(address(aapl), address(aaplFeed), true, _stockParams(1, 0, 0)));
        _listAsset(d, AssetSpec(address(nvda), address(nvdaFeed), true, _stockParams(1, 0, 0)));
        _listAsset(d, AssetSpec(address(tsla), address(tslaFeed), true, _stockParams(2, 0, 0)));

        address[4] memory users = [alice, bob, carol, liquidator];
        MockERC20[4] memory toks = [usdg, aapl, nvda, tsla];
        for (uint256 i; i < users.length; ++i) {
            for (uint256 j; j < toks.length; ++j) {
                vm.prank(users[i]);
                toks[j].approve(address(d.pool), type(uint256).max);
            }
        }
    }

    // ---------------- helpers ----------------

    function _rt(address asset) internal view returns (ReceiptToken) {
        return ReceiptToken(d.pool.getReserveData(asset).receiptToken);
    }

    function _dt(address asset) internal view returns (DebtToken) {
        return DebtToken(d.pool.getReserveData(asset).debtToken);
    }

    function _supply(address user, MockERC20 token, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        d.pool.supply(address(token), amount, user);
    }

    function _borrow(address user, MockERC20 token, uint256 amount) internal {
        vm.prank(user);
        d.pool.borrow(address(token), amount);
    }

    function _hf(address user) internal view returns (uint256) {
        return d.pool.getUserAccountData(user).healthFactor;
    }

    /// @dev Refresh every feed timestamp (keeps prices fresh after warps).
    function _refreshFeeds() internal {
        usdgFeed.set(usdgFeed.answer());
        aaplFeed.set(aaplFeed.answer());
        nvdaFeed.set(nvdaFeed.answer());
        tslaFeed.set(tslaFeed.answer());
    }

    function _warpBy(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        _refreshFeeds();
    }

    function _setParams(address asset, Types.RiskParams memory p) internal {
        d.assetConfig.setRiskParams(asset, p);
    }
}
