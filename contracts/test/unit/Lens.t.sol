// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {PoolLens} from "../../src/periphery/PoolLens.sol";
import {Types} from "../../src/libraries/Types.sol";

contract PoolLensTest is BaseTest {
    function test_markets_and_positions() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 10e18);
        _borrow(bob, usdg, 1_000e6);

        (PoolLens.Market[] memory m, bool open) = d.lens.getMarkets();
        assertTrue(open);
        assertEq(m.length, 4);
        assertEq(m[0].symbol, "USDG");
        assertEq(m[0].totalSupply, 10_000e6);
        assertEq(m[0].totalDebt, 1_000e6);
        assertEq(m[0].utilizationRay, 1e26);
        assertGt(m[0].borrowRateRay, m[0].supplyRateRay);
        assertTrue(m[1].priceOk);
        assertEq(m[1].priceWad, 200e18);
        assertEq(m[1].params.eModeCategory, 1);

        aaplFeed.setBroken(true); // oracle failure must not break the lens
        (m,) = d.lens.getMarkets();
        assertFalse(m[1].priceOk);
        aaplFeed.setBroken(false);

        (PoolLens.Position[] memory p, Types.AccountData memory a, uint8 em) = d.lens.getUserPositions(bob);
        assertEq(p[1].supplied, 10e18);
        assertTrue(p[1].collateral);
        assertEq(p[0].borrowed, 1_000e6);
        assertEq(a.debtUsd, 1_000e18);
        assertEq(em, 0);

        address[] memory users = new address[](2);
        (users[0], users[1]) = (alice, bob);
        Types.AccountData[] memory hfs = d.lens.getHealthFactors(users);
        assertEq(hfs[0].healthFactor, type(uint256).max);
        assertEq(hfs[1].healthFactor, 1_400e18 * 1e18 / 1_000e18);
    }
}
