// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LLErrors} from "../../src/libraries/LLErrors.sol";
import {ReceiptToken} from "../../src/core/ReceiptToken.sol";
import {IReserve} from "../../src/interfaces/IReserve.sol";

contract LiquidationTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _supply(alice, usdg, 100_000e6);
        _supply(bob, aapl, 10e18); // $2000
        _borrow(bob, usdg, 1_200e6); // LTV 60%, HF = 1400/1200
    }

    function test_cannotLiquidateHealthy() public {
        usdg.mint(liquidator, 1_000e6);
        vm.prank(liquidator);
        vm.expectRevert(LLErrors.HealthyAccount.selector);
        d.pool.liquidate(address(aapl), address(usdg), bob, 100e6, false);
    }

    function test_partialLiquidation_closeFactor50() public {
        aaplFeed.set(170e8); // HF ~0.99 -> 50% close factor
        uint256 hf0 = _hf(bob);
        assertLt(hf0, 1e18);
        assertGt(hf0, 0.95e18);
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = d.pool.liquidate(address(aapl), address(usdg), bob, type(uint256).max, false);
        assertEq(repaid, 600e6);
        // 600 / 170 * 1.08
        assertApproxEqRel(seized, uint256(600e18) * 108 / 100 / 170, 1e12);
        uint256 fee = (seized - seized * 10_000 / 10_800) / 10;
        assertApproxEqAbs(aapl.balanceOf(liquidator), seized - fee, 1e6);
        assertApproxEqAbs(_rt(address(aapl)).balanceOf(address(d.feeCollector)), fee, 1e6);
        assertGt(_hf(bob), hf0);
        assertApproxEqAbs(_dt(address(usdg)).balanceOf(bob), 600e6, 1);
    }

    function test_fullCloseFactor_belowThreshold() public {
        aaplFeed.set(160e8); // HF 0.933
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        (uint256 repaid,) = d.pool.liquidate(address(aapl), address(usdg), bob, type(uint256).max, false);
        assertEq(repaid, 1_200e6);
        assertEq(_dt(address(usdg)).scaledBalanceOf(bob), 0);
        assertEq(d.pool.getUserConfig(bob) & 1, 0);
    }

    function test_liquidation_receiveReceipt() public {
        aaplFeed.set(170e8);
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        (, uint256 seized) = d.pool.liquidate(address(aapl), address(usdg), bob, 300e6, true);
        uint256 fee = (seized - seized * 10_000 / 10_800) / 10;
        assertApproxEqAbs(_rt(address(aapl)).balanceOf(liquidator), seized - fee, 1e6);
        assertEq((d.pool.getUserConfig(liquidator) >> 3) & 1, 1);
        assertEq(aapl.balanceOf(liquidator), 0);
    }

    function test_badDebt_coveredByReserve_thenSocialized() public {
        // fund reserve with 300 USDG
        usdg.mint(address(d.reserve), 300e6);
        aaplFeed.set(50e8); // collateral $500 vs debt $1200
        uint256 supplyBefore = d.pool.totalSupplyAssets(address(usdg));
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = d.pool.liquidate(address(aapl), address(usdg), bob, type(uint256).max, false);
        assertEq(seized, 10e18);
        // repay = 10 * 50 / 1.08
        assertApproxEqAbs(repaid, uint256(500e6) * 10_000 / 10_800, 2);
        assertEq(_dt(address(usdg)).scaledBalanceOf(bob), 0);
        assertEq(d.pool.getUserConfig(bob), 0);
        assertEq(usdg.balanceOf(address(d.reserve)), 0);
        uint256 socialized = 1_200e6 - repaid - 300e6;
        assertApproxEqAbs(d.pool.totalSupplyAssets(address(usdg)), supplyBefore - socialized, 2);
        // solvency holds after socialization
        Types.ReserveData memory r = d.pool.getReserveData(address(usdg));
        assertGe(r.cash + d.pool.totalDebt(address(usdg)), d.pool.totalSupplyAssets(address(usdg)));
        assertEq(usdg.balanceOf(address(d.pool)), r.cash);
    }

    function test_badDebt_noReserve_fullySocialized() public {
        d.pool.setReserve(IReserve(address(0)));
        aaplFeed.set(50e8);
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        (uint256 repaid,) = d.pool.liquidate(address(aapl), address(usdg), bob, type(uint256).max, false);
        assertApproxEqAbs(d.pool.totalSupplyAssets(address(usdg)), 100_000e6 - (1_200e6 - repaid), 2);
    }

    function test_badDebt_multipleDebts() public {
        _supply(alice, nvda, 100e18);
        _supply(bob, usdg, 0.01e6);
        vm.prank(bob);
        d.pool.setUseAsCollateral(address(usdg), false);
        aaplFeed.set(230e8); // room for another $180 of debt
        _borrow(bob, nvda, 1e18); // $100 short
        aaplFeed.set(30e8);
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        d.pool.liquidate(address(aapl), address(usdg), bob, type(uint256).max, false);
        assertEq(_dt(address(nvda)).scaledBalanceOf(bob), 0);
        assertEq(_dt(address(usdg)).scaledBalanceOf(bob), 0);
    }

    function test_noBadDebt_ifOtherCollateralRemains() public {
        _supply(bob, nvda, 1e18); // $100 extra collateral
        aaplFeed.set(50e8);
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        d.pool.liquidate(address(aapl), address(usdg), bob, type(uint256).max, false);
        assertGt(_dt(address(usdg)).scaledBalanceOf(bob), 0);
    }

    function test_liquidation_reverts() public {
        aaplFeed.set(160e8);
        vm.startPrank(liquidator);
        vm.expectRevert(LLErrors.ZeroAmount.selector);
        d.pool.liquidate(address(aapl), address(usdg), bob, 0, false);
        vm.expectRevert(LLErrors.NoCollateral.selector);
        d.pool.liquidate(address(nvda), address(usdg), bob, 1e6, false);
        vm.expectRevert(LLErrors.NoDebt.selector);
        d.pool.liquidate(address(aapl), address(nvda), bob, 1e6, false);
        vm.stopPrank();
        d.pool.setReserveFlags(address(aapl), false, true);
        vm.prank(liquidator);
        vm.expectRevert(LLErrors.ReservePaused.selector);
        d.pool.liquidate(address(aapl), address(usdg), bob, 1e6, false);
    }

    function test_liquidation_insufficientCollateralCash() public {
        // drain AAPL cash: carol borrows all AAPL supplied by bob
        _supply(carol, usdg, 1_000_000e6);
        _borrow(carol, aapl, 10e18);
        aaplFeed.set(160e8);
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        vm.expectRevert(LLErrors.InsufficientLiquidity.selector);
        d.pool.liquidate(address(aapl), address(usdg), bob, 100e6, false);
        // receipt route still works
        vm.prank(liquidator);
        d.pool.liquidate(address(aapl), address(usdg), bob, 100e6, true);
    }

    function test_moduleDirectCall_reverts() public {
        vm.expectRevert(LLErrors.OnlyDelegateCall.selector);
        d.liquidationLogic.liquidate(address(aapl), address(usdg), bob, 1, false, address(this));
    }

    function test_liquidation_eModeBonus() public {
        _supply(alice, nvda, 100e18);
        _supply(carol, aapl, 10e18);
        vm.prank(carol);
        d.pool.setEMode(1);
        _borrow(carol, nvda, 15e18); // $1500 of $2000, LT 80%
        nvdaFeed.set(110e8); // debt $1650 > $1600
        assertLt(_hf(carol), 1e18);
        nvda.mint(liquidator, 100e18);
        vm.prank(liquidator);
        nvda.approve(address(d.pool), type(uint256).max);
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = d.pool.liquidate(address(aapl), address(nvda), carol, 5e18, false);
        assertEq(repaid, 5e18);
        // 5 * 110 / 200 * 1.05 (e-mode bonus)
        assertApproxEqRel(seized, uint256(5e18) * 110 * 105 / 200 / 100, 1e12);
    }
}
