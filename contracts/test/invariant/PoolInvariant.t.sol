// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Handler} from "./Handler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {ReceiptToken} from "../../src/core/ReceiptToken.sol";
import {Types} from "../../src/libraries/Types.sol";
import {IMarketClock} from "../../src/interfaces/IMarketClock.sol";

contract PoolInvariantTest is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        // Remove the clock so random warps don't make every stock feed "stale"-sensitive to sessions;
        // closed-market behaviour is covered by unit and fuzz tests.
        d.pool.setMarketClock(IMarketClock(address(0)));

        MockERC20[] memory a = new MockERC20[](3);
        (a[0], a[1], a[2]) = (usdg, aapl, tsla);
        MockAggregator[] memory f = new MockAggregator[](3);
        (f[0], f[1], f[2]) = (usdgFeed, aaplFeed, tslaFeed);
        address[] memory actors = new address[](4);
        (actors[0], actors[1], actors[2], actors[3]) = (alice, bob, carol, liquidator);
        handler = new Handler(d.pool, a, f, actors);
        targetContract(address(handler));
    }

    function _tolerance() internal view returns (uint256) {
        return 10 + handler.ops() * 3;
    }

    /// Total borrows never exceed total supply (up to protocol-favourable rounding dust).
    function invariant_borrowsNeverExceedSupply() public view {
        address[] memory list = d.pool.getReservesList();
        for (uint256 i; i < list.length; ++i) {
            assertLe(d.pool.totalDebt(list[i]), d.pool.totalSupplyAssets(list[i]) + _tolerance(), "debt > supply");
        }
    }

    /// Every claim is backed: cash + debt >= supplier claims, and tracked cash is really held.
    function invariant_solvency() public view {
        address[] memory list = d.pool.getReservesList();
        for (uint256 i; i < list.length; ++i) {
            Types.ReserveData memory r = d.pool.getReserveData(list[i]);
            assertGe(r.cash + d.pool.totalDebt(list[i]), d.pool.totalSupplyAssets(list[i]), "insolvent");
            assertGe(MockERC20(list[i]).balanceOf(address(d.pool)), r.cash, "cash not held");
        }
    }

    /// No healthy account was ever liquidated.
    function invariant_noHealthyLiquidation() public view {
        assertFalse(handler.healthyLiquidated());
    }

    /// Receipt tokens always redeem for at least their share, and the sum of all shares' value
    /// never exceeds the reserve's total supply assets.
    function invariant_receiptRedeemsShare() public view {
        assertFalse(handler.redeemShortfall());
        address[] memory list = d.pool.getReservesList();
        for (uint256 i; i < list.length; ++i) {
            ReceiptToken rt = ReceiptToken(d.pool.getReserveData(list[i]).receiptToken);
            uint256 sum;
            for (uint256 j; j < handler.actorsLength(); ++j) {
                sum += rt.convertToAssets(rt.balanceOf(handler.actors(j)));
            }
            sum += rt.convertToAssets(rt.balanceOf(address(d.feeCollector)));
            assertLe(sum, d.pool.totalSupplyAssets(list[i]), "claims exceed supply");
        }
    }

    /// Indices are sane: borrow index never below RAY, liquidity index positive.
    function invariant_indices() public view {
        address[] memory list = d.pool.getReservesList();
        for (uint256 i; i < list.length; ++i) {
            Types.ReserveData memory r = d.pool.getReserveData(list[i]);
            assertGe(r.borrowIndex, 1e27);
            assertGt(r.liquidityIndex, 0);
        }
    }
}

