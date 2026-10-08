// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LLErrors} from "../../src/libraries/LLErrors.sol";

contract PoolFuzzTest is BaseTest {
    /// Supply then withdraw-all never returns more than supplied (no free value from rounding).
    function testFuzz_supplyWithdraw_noProfit(uint256 amount, uint256 seedSupply) public {
        amount = bound(amount, 1, 1e15 * 1e6);
        seedSupply = bound(seedSupply, 1e6, 1e12 * 1e6);
        _supply(carol, usdg, seedSupply);
        _supply(alice, usdg, amount);
        vm.prank(alice);
        uint256 out = d.pool.withdraw(address(usdg), type(uint256).max, alice);
        assertLe(out, amount);
        assertGe(out + 1, amount);
    }

    /// Interest never makes a supplier's claim exceed what the pool can back.
    function testFuzz_interest_solvency(uint256 supplyAmt, uint256 borrowBps, uint256 dt) public {
        supplyAmt = bound(supplyAmt, 1e6, 1e12 * 1e6);
        borrowBps = bound(borrowBps, 1, 10_000);
        dt = bound(dt, 1, 5 * 365 days);
        _supply(alice, usdg, supplyAmt);
        _supply(bob, aapl, supplyAmt * 1e12); // $200 of AAPL per $1 borrowed: always enough
        uint256 b = supplyAmt * borrowBps / 10_000;
        if (b == 0) return;
        _borrow(bob, usdg, b);
        _warpBy(dt);
        d.pool.accrue(address(usdg));
        Types.ReserveData memory r = d.pool.getReserveData(address(usdg));
        uint256 debt = d.pool.totalDebt(address(usdg));
        uint256 sup = d.pool.totalSupplyAssets(address(usdg));
        assertGe(r.cash + debt, sup, "insolvent");
        assertGe(r.liquidityIndex, 1e27);
        assertGe(r.borrowIndex, r.liquidityIndex);
    }

    /// Borrowing up to LTV succeeds, one unit above LTV fails.
    function testFuzz_borrowLimit(uint256 collateral) public {
        collateral = bound(collateral, 1e18, 1e9 * 1e18);
        _supply(alice, usdg, type(uint96).max);
        _supply(bob, aapl, collateral);
        uint256 maxUsd = collateral * 200 * 6_000 / 10_000; // 18-dec USD
        uint256 maxBorrow = maxUsd / 1e12; // to 6 decimals
        vm.prank(bob);
        vm.expectRevert(LLErrors.InsufficientCollateral.selector);
        d.pool.borrow(address(usdg), maxBorrow + 1);
        _borrow(bob, usdg, maxBorrow);
        assertGe(_hf(bob), 1e18);
    }

    /// For any price move: healthy accounts revert, unhealthy ones improve or get cleared.
    function testFuzz_liquidation(uint256 newPrice, uint256 repayAmt) public {
        newPrice = bound(newPrice, 1e8, 400e8);
        repayAmt = bound(repayAmt, 1, 2_000e6);
        _supply(alice, usdg, 100_000e6);
        _supply(bob, aapl, 10e18);
        _borrow(bob, usdg, 1_200e6);
        aaplFeed.set(int256(newPrice));
        uint256 hf0 = _hf(bob);
        usdg.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        if (hf0 >= 1e18) {
            vm.expectRevert(LLErrors.HealthyAccount.selector);
            d.pool.liquidate(address(aapl), address(usdg), bob, repayAmt, false);
            return;
        }
        try d.pool.liquidate(address(aapl), address(usdg), bob, repayAmt, false) returns (uint256 repaid, uint256) {
            assertLe(repaid, repayAmt);
            uint256 hf1 = _hf(bob);
            if (_rt(address(aapl)).balanceOf(bob) == 0) {
                // collateral exhausted -> remaining debt must have been written off
                assertEq(_dt(address(usdg)).scaledBalanceOf(bob), 0);
            } else if (hf0 > 0.756e18 && hf1 != type(uint256).max) {
                // above LT * (1 + bonus) a liquidation can only improve health
                assertGe(hf1 + 1e9, hf0);
            }
        } catch (bytes memory err) {
            // only acceptable failure: dust repay rounds to zero
            assertEq(bytes4(err), LLErrors.ZeroAmount.selector);
        }
    }

    /// Market-closed LTV is never above the open LTV.
    function testFuzz_closedLtv(uint256 ts) public {
        ts = bound(ts, OPEN_TS, OPEN_TS + 365 days);
        _supply(bob, aapl, 10e18);
        vm.warp(ts);
        _refreshFeeds();
        uint256 power = d.pool.getUserAccountData(bob).borrowPowerUsd;
        if (d.clock.isMarketOpen()) assertEq(power, 1_200e18);
        else assertEq(power, 800e18);
    }
}
