// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LLErrors} from "../../src/libraries/LLErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IMarketClock} from "../../src/interfaces/IMarketClock.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {IReserve} from "../../src/interfaces/IReserve.sol";
import {IProjectTokenHooks} from "../../src/interfaces/IProjectTokenHooks.sol";
import {Pool} from "../../src/core/Pool.sol";
import {ReceiptToken} from "../../src/core/ReceiptToken.sol";
import {IAssetConfig} from "../../src/interfaces/IAssetConfig.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract PoolTest is BaseTest {
    function test_supply_mintsSharesAndEnablesCollateral() public {
        _supply(alice, usdg, 1_000e6);
        assertEq(_rt(address(usdg)).balanceOf(alice), 1_000e6);
        assertEq(d.pool.totalSupplyAssets(address(usdg)), 1_000e6);
        assertEq(d.pool.getReserveData(address(usdg)).cash, 1_000e6);
        assertEq(d.pool.getUserConfig(alice) & 2, 2); // collateral bit for id 0
        assertEq(usdg.balanceOf(address(d.pool)), 1_000e6);
    }

    function test_supply_reverts() public {
        vm.expectRevert(LLErrors.ZeroAmount.selector);
        d.pool.supply(address(usdg), 0, alice);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.pool.supply(address(usdg), 1, address(0));
        vm.expectRevert(LLErrors.ReserveNotActive.selector);
        d.pool.supply(address(0xdead), 1, alice);
    }

    function test_supplyCap() public {
        Types.RiskParams memory p = _stableParams(1_000e6, 0);
        _setParams(address(usdg), p);
        _supply(alice, usdg, 1_000e6);
        usdg.mint(bob, 1);
        vm.prank(bob);
        vm.expectRevert(LLErrors.SupplyCapExceeded.selector);
        d.pool.supply(address(usdg), 1, bob);
    }

    function test_withdraw_full_and_partial() public {
        _supply(alice, usdg, 1_000e6);
        vm.prank(alice);
        d.pool.withdraw(address(usdg), 400e6, alice);
        assertEq(usdg.balanceOf(alice), 400e6);
        vm.prank(alice);
        uint256 w = d.pool.withdraw(address(usdg), type(uint256).max, alice);
        assertEq(w, 600e6);
        assertEq(_rt(address(usdg)).balanceOf(alice), 0);
        assertEq(d.pool.getUserConfig(alice), 0);
    }

    function test_withdraw_reverts() public {
        _supply(alice, usdg, 100e6);
        vm.startPrank(alice);
        vm.expectRevert(LLErrors.ZeroAmount.selector);
        d.pool.withdraw(address(usdg), 0, alice);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.pool.withdraw(address(usdg), 1, address(0));
        vm.expectRevert(LLErrors.InsufficientBalance.selector);
        d.pool.withdraw(address(usdg), 101e6, alice);
        vm.stopPrank();
    }

    function test_withdraw_insufficientLiquidity() public {
        _supply(alice, usdg, 1_000e6);
        _supply(bob, aapl, 100e18); // $20k collateral
        _borrow(bob, usdg, 900e6);
        vm.prank(alice);
        vm.expectRevert(LLErrors.InsufficientLiquidity.selector);
        d.pool.withdraw(address(usdg), 200e6, alice);
    }

    function test_borrow_and_repay() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18); // $2000, ltv 60% -> $1200
        _borrow(bob, usdg, 1_000e6);
        assertEq(usdg.balanceOf(bob), 1_000e6);
        assertEq(_dt(address(usdg)).balanceOf(bob), 1_000e6);
        assertGt(d.pool.getReserveData(address(usdg)).borrowRateRay, 0);

        _warpBy(365 days);
        uint256 debt = _dt(address(usdg)).balanceOf(bob);
        assertGt(debt, 1_000e6);
        usdg.mint(bob, debt);
        vm.prank(bob);
        uint256 repaid = d.pool.repay(address(usdg), type(uint256).max, bob);
        assertEq(repaid, debt);
        assertEq(_dt(address(usdg)).scaledBalanceOf(bob), 0);
        assertEq(d.pool.getUserConfig(bob) & 1, 0);
        // Suppliers earned interest
        assertGt(d.pool.totalSupplyAssets(address(usdg)), 10_000e6);
    }

    function test_repay_partial_and_onBehalf() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18);
        _borrow(bob, usdg, 1_000e6);
        usdg.mint(carol, 400e6);
        vm.prank(carol);
        usdg.approve(address(d.pool), type(uint256).max);
        vm.prank(carol);
        d.pool.repay(address(usdg), 400e6, bob);
        assertApproxEqAbs(_dt(address(usdg)).balanceOf(bob), 600e6, 1);
        vm.expectRevert(LLErrors.NoDebt.selector);
        d.pool.repay(address(usdg), 1, carol);
        vm.expectRevert(LLErrors.ZeroAmount.selector);
        d.pool.repay(address(usdg), 0, bob);
    }

    function test_borrow_exceedsLtv_reverts() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18); // $2000 * 60% = $1200
        vm.prank(bob);
        vm.expectRevert(LLErrors.InsufficientCollateral.selector);
        d.pool.borrow(address(usdg), 1_201e6);
        _borrow(bob, usdg, 1_200e6);
    }

    function test_borrow_reverts_misc() public {
        _supply(alice, usdg, 10_000e6);
        vm.startPrank(bob);
        vm.expectRevert(LLErrors.ZeroAmount.selector);
        d.pool.borrow(address(usdg), 0);
        vm.expectRevert(LLErrors.InsufficientLiquidity.selector);
        d.pool.borrow(address(usdg), 10_001e6);
        vm.expectRevert(LLErrors.InsufficientCollateral.selector);
        d.pool.borrow(address(usdg), 1e6);
        vm.stopPrank();
    }

    function test_borrowDisabled_and_cap() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 100e18);
        Types.RiskParams memory p = _stableParams(0, 500e6);
        _setParams(address(usdg), p);
        vm.prank(bob);
        vm.expectRevert(LLErrors.BorrowCapExceeded.selector);
        d.pool.borrow(address(usdg), 501e6);
        p.borrowEnabled = false;
        _setParams(address(usdg), p);
        vm.prank(bob);
        vm.expectRevert(LLErrors.BorrowingDisabled.selector);
        d.pool.borrow(address(usdg), 1e6);
    }

    function test_shortStock_borrowAgainstStable() public {
        _supply(alice, aapl, 100e18);
        _supply(bob, usdg, 10_000e6); // $8000 power
        _borrow(bob, aapl, 30e18); // $6000 short
        assertEq(aapl.balanceOf(bob), 30e18);
        // Price rises 50% -> short underwater: debt $9000 vs threshold $8500
        aaplFeed.set(300e8);
        assertLt(_hf(bob), 1e18);
    }

    // ---------------- market-hours guard ----------------

    function test_closedMarket_lowersLtv() public {
        _supply(alice, usdg, 100_000e6);
        _supply(bob, aapl, 10e18); // $2000
        vm.warp(WEEKEND_TS);
        _refreshFeeds();
        assertFalse(d.pool.isMarketOpen());
        // closed LTV for tier-1 is 40% -> $800
        vm.prank(bob);
        vm.expectRevert(LLErrors.InsufficientCollateral.selector);
        d.pool.borrow(address(usdg), 900e6);
        _borrow(bob, usdg, 800e6);
        Types.AccountData memory a = d.pool.getUserAccountData(bob);
        assertEq(a.borrowPowerUsd, 800e18);
    }

    function test_closedMarket_stockBorrowCap() public {
        // borrowCap 100 => closed cap 20
        _setParams(address(aapl), _stockParams(1, 0, 100e18));
        _supply(alice, aapl, 100e18);
        _supply(bob, usdg, 1_000_000e6);
        vm.warp(WEEKEND_TS);
        _refreshFeeds();
        vm.prank(bob);
        vm.expectRevert(LLErrors.ClosedMarketBorrowCapExceeded.selector);
        d.pool.borrow(address(aapl), 21e18);
        _borrow(bob, aapl, 20e18);
        // reopen: allowed up to borrowCap
        vm.warp(OPEN_TS + 7 days);
        _refreshFeeds();
        _borrow(bob, aapl, 50e18);
    }

    function test_noClock_alwaysOpen() public {
        d.pool.setMarketClock(IMarketClock(address(0)));
        vm.warp(WEEKEND_TS);
        assertTrue(d.pool.isMarketOpen());
    }

    // ---------------- collateral toggles / e-mode ----------------

    function test_setUseAsCollateral() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18);
        _supply(bob, nvda, 10e18);
        _borrow(bob, usdg, 1_000e6);
        vm.prank(bob);
        d.pool.setUseAsCollateral(address(nvda), false); // still covered by AAPL ($1200 power)
        vm.prank(bob);
        vm.expectRevert(LLErrors.InsufficientCollateral.selector);
        d.pool.setUseAsCollateral(address(aapl), false);
        vm.prank(bob);
        d.pool.setUseAsCollateral(address(nvda), true);

        vm.prank(carol);
        vm.expectRevert(LLErrors.InsufficientBalance.selector);
        d.pool.setUseAsCollateral(address(nvda), true);

        Types.RiskParams memory p = _stockParams(1, 0, 0);
        p.collateralEnabled = false;
        _setParams(address(nvda), p);
        vm.prank(bob);
        vm.expectRevert(LLErrors.CollateralDisabled.selector);
        d.pool.setUseAsCollateral(address(nvda), true);
    }

    function test_eMode_boostsLtv_and_restrictsBorrows() public {
        _supply(alice, nvda, 100e18);
        _supply(alice, usdg, 100_000e6);
        _supply(bob, aapl, 10e18); // $2000, tech e-mode LTV 75% -> $1500
        vm.prank(bob);
        d.pool.setEMode(1);
        assertEq(d.pool.getUserEMode(bob), 1);
        assertEq(d.pool.getUserAccountData(bob).borrowPowerUsd, 1_500e18);
        // borrowing a non-category asset is blocked
        vm.prank(bob);
        vm.expectRevert(LLErrors.EModeMismatch.selector);
        d.pool.borrow(address(usdg), 1e6);
        _borrow(bob, nvda, 14e18); // $1400
        // leaving e-mode would make the account unsafe
        vm.prank(bob);
        vm.expectRevert(LLErrors.InsufficientCollateral.selector);
        d.pool.setEMode(0);
    }

    function test_eMode_cannotEnterWithForeignDebt() public {
        _supply(alice, usdg, 100_000e6);
        _supply(bob, aapl, 10e18);
        _borrow(bob, usdg, 100e6);
        vm.prank(bob);
        vm.expectRevert(LLErrors.EModeMismatch.selector);
        d.pool.setEMode(1);
        vm.prank(bob);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.pool.setEMode(9);
    }

    // ---------------- receipt transfers ----------------

    function test_receiptTransfer_checksHealth() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18);
        _borrow(bob, usdg, 1_000e6);
        ReceiptToken rt = _rt(address(aapl));
        vm.startPrank(bob);
        vm.expectRevert(LLErrors.InsufficientCollateral.selector);
        rt.transfer(carol, 5e18);
        rt.transfer(carol, 1e18);
        vm.stopPrank();
        assertEq(_rt(address(aapl)).balanceOf(carol), 1e18);
        assertEq((d.pool.getUserConfig(carol) >> 3) & 1, 1); // aapl id 1 collateral bit
    }

    function test_receiptTransfer_fullBalanceClearsCollateral() public {
        _supply(bob, aapl, 10e18);
        ReceiptToken rt = _rt(address(aapl));
        vm.prank(bob);
        rt.approve(carol, 10e18);
        vm.prank(carol);
        rt.transferFrom(bob, carol, 10e18);
        assertEq(d.pool.getUserConfig(bob), 0);
    }

    function test_finalizeTransfer_onlyReceipt() public {
        vm.expectRevert(LLErrors.OnlyReceiptToken.selector);
        d.pool.finalizeTransfer(address(usdg), alice, bob, 1);
        vm.expectRevert(LLErrors.OnlyReceiptToken.selector);
        d.pool.vaultWithdraw(address(usdg), alice, bob, 1, false);
    }

    // ---------------- pause / freeze ----------------

    function test_globalPause_blocksAllButRepay() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18);
        _borrow(bob, usdg, 100e6);
        vm.prank(guardian);
        d.pool.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.pool.supply(address(usdg), 1, alice);
        vm.prank(bob);
        d.pool.repay(address(usdg), 50e6, bob);
        // guardian cannot unpause; admin (timelock) can
        vm.prank(guardian);
        vm.expectRevert();
        d.pool.unpause();
        d.pool.unpause();
        _supply(alice, usdg, 1e6);
    }

    function test_reserveFlags_guardianCanOnlyTighten() public {
        vm.prank(guardian);
        d.pool.setReserveFlags(address(aapl), true, false);
        aapl.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(LLErrors.ReserveFrozen.selector);
        d.pool.supply(address(aapl), 1e18, alice);
        vm.prank(guardian);
        vm.expectRevert();
        d.pool.setReserveFlags(address(aapl), false, false);
        vm.prank(guardian);
        d.pool.setReserveFlags(address(aapl), true, true);
        vm.prank(alice);
        vm.expectRevert(LLErrors.ReservePaused.selector);
        d.pool.withdraw(address(aapl), 1, alice);
        vm.prank(bob);
        vm.expectRevert();
        d.pool.setReserveFlags(address(aapl), true, true);
        d.pool.setReserveFlags(address(aapl), false, false);
    }

    function test_frozenReserve_blocksBorrow_pausedBlocksSupply() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18);
        d.pool.setReserveFlags(address(usdg), true, false);
        vm.prank(bob);
        vm.expectRevert(LLErrors.ReserveFrozen.selector);
        d.pool.borrow(address(usdg), 1e6);
        d.pool.setReserveFlags(address(usdg), false, true);
        vm.prank(bob);
        vm.expectRevert(LLErrors.ReservePaused.selector);
        d.pool.borrow(address(usdg), 1e6);
        usdg.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(LLErrors.ReservePaused.selector);
        d.pool.supply(address(usdg), 1, alice);
    }

    // ---------------- compliance ----------------

    function test_compliance_gatesSupplyBorrow_notRepayWithdraw() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18);
        _borrow(bob, usdg, 100e6);
        d.compliance.setEnabled(true);
        usdg.mint(carol, 1e6);
        vm.prank(carol);
        usdg.approve(address(d.pool), 1e6);
        vm.prank(carol);
        vm.expectRevert(LLErrors.NotCompliant.selector);
        d.pool.supply(address(usdg), 1e6, carol);
        vm.prank(bob);
        vm.expectRevert(LLErrors.NotCompliant.selector);
        d.pool.borrow(address(usdg), 1e6);
        vm.prank(bob);
        d.pool.repay(address(usdg), 10e6, bob);
        vm.prank(alice);
        d.pool.withdraw(address(usdg), 1e6, alice);
        ReceiptToken rt = _rt(address(aapl));
        vm.prank(bob);
        vm.expectRevert(LLErrors.NotCompliant.selector);
        rt.transfer(carol, 1e17);

        address[] memory list = new address[](1);
        list[0] = carol;
        vm.prank(gov);
        d.compliance.setAllowed(list, true);
        vm.prank(carol);
        d.pool.supply(address(usdg), 1e6, carol);
    }

    // ---------------- interest & treasury ----------------

    function test_interest_accrual_and_mintToTreasury() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 100e18);
        _borrow(bob, usdg, 8_000e6);
        _warpBy(30 days);
        uint256 liBefore = d.pool.getNormalizedIncome(address(usdg));
        assertGt(liBefore, 1e27);
        d.pool.accrue(address(usdg));
        Types.ReserveData memory r = d.pool.getReserveData(address(usdg));
        assertEq(r.liquidityIndex, liBefore);
        assertGt(r.accruedToTreasuryScaled, 0);
        d.pool.mintToTreasury(address(usdg));
        assertEq(_rt(address(usdg)).balanceOf(address(d.feeCollector)), r.accruedToTreasuryScaled);
        assertEq(d.pool.getReserveData(address(usdg)).accruedToTreasuryScaled, 0);
        d.pool.mintToTreasury(address(usdg)); // no-op
    }

    function test_solvency_afterAccrual() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 100e18);
        _borrow(bob, usdg, 9_000e6);
        _warpBy(365 days);
        d.pool.accrue(address(usdg));
        Types.ReserveData memory r = d.pool.getReserveData(address(usdg));
        assertGe(r.cash + d.pool.totalDebt(address(usdg)), d.pool.totalSupplyAssets(address(usdg)));
    }

    function test_skim_sendsDonationsToFeeCollector() public {
        _supply(alice, usdg, 1_000e6);
        usdg.mint(address(d.pool), 55e6);
        d.pool.skim(address(usdg));
        assertEq(usdg.balanceOf(address(d.feeCollector)), 55e6);
        d.pool.skim(address(usdg)); // nothing left
        // exchange rate unaffected by donation
        assertEq(d.pool.getNormalizedIncome(address(usdg)), 1e27);
    }

    // ---------------- admin ----------------

    function test_admin_setters_and_access() public {
        vm.startPrank(alice);
        vm.expectRevert();
        d.pool.setOracle(IPriceOracle(address(1)));
        vm.expectRevert();
        d.pool.setFlashFeeBps(1);
        vm.expectRevert();
        d.pool.initReserve(address(1), address(2), address(3));
        vm.stopPrank();

        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.pool.setOracle(IPriceOracle(address(0)));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.pool.setFeeCollector(address(0));
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.pool.setFlashFeeBps(101);
        d.pool.setFlashFeeBps(9);
        d.pool.setCompliance(IComplianceRegistry(address(0)));
        d.pool.setReserve(IReserve(address(0)));
        d.pool.setProjectTokenHooks(IProjectTokenHooks(address(0)));
        (,,, address comp,,,, uint16 fee) = d.pool.modules();
        assertEq(comp, address(0));
        assertEq(fee, 9);
    }

    function test_initReserve_guards() public {
        vm.startPrank(address(d.assetConfig));
        vm.expectRevert(LLErrors.ReserveAlreadyListed.selector);
        d.pool.initReserve(address(usdg), address(1), address(1));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.pool.initReserve(address(0), address(1), address(1));
        for (uint160 i = 100; i < 128; ++i) {
            d.pool.initReserve(address(i), address(1), address(1));
        }
        vm.expectRevert(LLErrors.TooManyReserves.selector);
        d.pool.initReserve(address(999), address(1), address(1));
        vm.stopPrank();
    }

    function test_constructor_zeroChecks() public {
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new Pool(address(0), guardian, d.assetConfig, address(1), address(1));
    }

    function test_views() public {
        _supply(alice, usdg, 1_000e6);
        assertEq(d.pool.getReservesList().length, 4);
        assertEq(d.pool.getNormalizedDebt(address(usdg)), 1e27);
        assertEq(d.pool.totalDebt(address(usdg)), 0);
        assertEq(d.pool.maxFlashLoan(address(usdg)), 1_000e6);
        assertEq(d.pool.maxFlashLoan(address(0xbeef)), 0);
        assertEq(d.pool.flashFee(address(usdg), 10_000e6), 5e6);
        vm.expectRevert(LLErrors.ReserveNotActive.selector);
        d.pool.flashFee(address(0xbeef), 1);
        Types.AccountData memory a = d.pool.getUserAccountData(alice);
        assertEq(a.collateralUsd, 1_000e18);
        assertEq(a.healthFactor, type(uint256).max);
    }
}
