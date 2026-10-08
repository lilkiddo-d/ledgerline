// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../../src/core/Pool.sol";
import {ReceiptToken} from "../../src/core/ReceiptToken.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

/// @notice Drives random sequences of user actions against the Pool and records ghost violations.
contract Handler is Test {
    Pool public pool;
    MockERC20[] public assets;
    MockAggregator[] public feeds;
    address[] public actors;
    MockFlashBorrower public fb;

    // ghost state
    bool public healthyLiquidated;
    bool public redeemShortfall;
    uint256 public ops;
    mapping(bytes32 => uint256) public calls;

    constructor(Pool pool_, MockERC20[] memory assets_, MockAggregator[] memory feeds_, address[] memory actors_) {
        pool = pool_;
        for (uint256 i; i < assets_.length; ++i) {
            assets.push(assets_[i]);
            feeds.push(feeds_[i]);
        }
        actors = actors_;
        fb = new MockFlashBorrower(address(pool_));
        for (uint256 i; i < actors_.length; ++i) {
            for (uint256 j; j < assets_.length; ++j) {
                vm.prank(actors_[i]);
                assets_[j].approve(address(pool_), type(uint256).max);
            }
        }
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _asset(uint256 s) internal view returns (MockERC20) {
        return assets[s % assets.length];
    }

    function _unit(MockERC20 a) internal view returns (uint256) {
        return 10 ** a.decimals();
    }

    function _refresh() internal {
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].set(feeds[i].answer());
        }
    }

    function supply(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address u = _actor(actorSeed);
        MockERC20 a = _asset(assetSeed);
        amount = bound(amount, 1, 1_000_000 * _unit(a));
        a.mint(u, amount);
        vm.prank(u);
        try pool.supply(address(a), amount, u) {
            ops++;
            calls["supply"]++;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 assetSeed, uint256 amount, bool all) external {
        address u = _actor(actorSeed);
        MockERC20 a = _asset(assetSeed);
        ReceiptToken rt = ReceiptToken(pool.getReserveData(address(a)).receiptToken);
        uint256 owed = rt.convertToAssets(rt.balanceOf(u));
        if (owed == 0) return;
        amount = all ? type(uint256).max : bound(amount, 1, owed);
        uint256 before = a.balanceOf(u);
        vm.prank(u);
        try pool.withdraw(address(a), amount, u) returns (uint256 got) {
            ops++;
            calls["withdraw"]++;
            if (all && got < owed) redeemShortfall = true;
            if (a.balanceOf(u) - before != got) redeemShortfall = true;
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address u = _actor(actorSeed);
        MockERC20 a = _asset(assetSeed);
        Types.AccountData memory acc = pool.getUserAccountData(u);
        if (acc.borrowPowerUsd <= acc.debtUsd) return;
        uint256 price = uint256(feeds[assetSeed % feeds.length].answer()) * 1e10;
        uint256 maxAmt = (acc.borrowPowerUsd - acc.debtUsd) * _unit(a) / price;
        uint256 cash = pool.getReserveData(address(a)).cash;
        if (maxAmt > cash) maxAmt = cash;
        if (maxAmt == 0) return;
        amount = bound(amount, maxAmt / 2 + 1, maxAmt); // push accounts toward their limit
        vm.prank(u);
        try pool.borrow(address(a), amount) {
            ops++;
            calls["borrow"]++;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address u = _actor(actorSeed);
        MockERC20 a = _asset(assetSeed);
        amount = bound(amount, 1, 2_000_000 * _unit(a));
        a.mint(u, amount);
        vm.prank(u);
        try pool.repay(address(a), amount, u) {
            ops++;
            calls["repay"]++;
        } catch {}
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1, 30 days);
        vm.warp(block.timestamp + dt);
        _refresh();
        ops++;
    }

    /// Moves a stock price by -40%..+40%.
    function movePrice(uint256 feedSeed, uint256 pctSeed) external {
        uint256 i = 1 + feedSeed % (feeds.length - 1); // never move the stablecoin
        int256 p = feeds[i].answer();
        int256 pct = int256(bound(pctSeed, 50, 150));
        int256 np = p * pct / 100;
        if (np < 1e8) np = 1e8;
        if (np > 100_000e8) np = 100_000e8;
        feeds[i].set(np);
    }

    /// Guided shock: drops the price of one of the user's stock collateral assets by 45%.
    function crash(uint256 userSeed) external {
        address user = _actor(userSeed);
        uint256 cfg = pool.getUserConfig(user);
        for (uint256 i = 1; i < assets.length; ++i) {
            uint256 id = pool.getReserveData(address(assets[i])).id;
            if ((cfg >> (id * 2 + 1)) & 1 == 1) {
                int256 np = feeds[i].answer() * 55 / 100;
                feeds[i].set(np < 1e8 ? int256(1e8) : np);
                calls["crash"]++;
                return;
            }
        }
    }

    /// Picks a real (collateral, debt) pair of the target account so liquidations actually happen.
    function liquidate(uint256 liqSeed, uint256 userSeed, uint256 amount, bool receipt) external {
        address liq = _actor(liqSeed);
        address user = _actor(userSeed);
        if (liq == user) return;
        (MockERC20 coll, MockERC20 debt) = _pair(user, amount);
        if (address(coll) == address(0) || address(debt) == address(0)) return;
        uint256 hf = pool.getUserAccountData(user).healthFactor;
        amount = bound(amount, 1, 1_000_000 * _unit(debt));
        debt.mint(liq, amount);
        vm.prank(liq);
        try pool.liquidate(address(coll), address(debt), user, amount, receipt) {
            ops++;
            calls["liquidate"]++;
            if (hf >= 1e18) healthyLiquidated = true;
        } catch {}
    }

    function _pair(address user, uint256 seed) internal view returns (MockERC20 coll, MockERC20 debt) {
        uint256 cfg = pool.getUserConfig(user);
        uint256 n = assets.length;
        for (uint256 k; k < n; ++k) {
            uint256 i = (seed + k) % n;
            uint256 id = pool.getReserveData(address(assets[i])).id;
            if (address(coll) == address(0) && (cfg >> (id * 2 + 1)) & 1 == 1) coll = assets[i];
            if (address(debt) == address(0) && (cfg >> (id * 2)) & 1 == 1) debt = assets[i];
        }
    }

    /// Unguided variant: random pair, may target healthy accounts (must always revert then).
    function liquidateRandom(uint256 liqSeed, uint256 userSeed, uint256 collSeed, uint256 debtSeed, uint256 amount)
        external
    {
        address liq = _actor(liqSeed);
        address user = _actor(userSeed);
        MockERC20 coll = _asset(collSeed);
        MockERC20 debt = _asset(debtSeed);
        uint256 hf = pool.getUserAccountData(user).healthFactor;
        amount = bound(amount, 1, 1_000_000 * _unit(debt));
        debt.mint(liq, amount);
        vm.prank(liq);
        try pool.liquidate(address(coll), address(debt), user, amount, false) {
            if (hf >= 1e18) healthyLiquidated = true;
        } catch {}
    }

    function flashLoan(uint256 assetSeed, uint256 amount) external {
        MockERC20 a = _asset(assetSeed);
        uint256 cash = pool.getReserveData(address(a)).cash;
        if (cash == 0) return;
        amount = bound(amount, 1, cash);
        a.mint(address(fb), amount / 100 + 1);
        try pool.flashLoan(IERC3156FlashBorrower(address(fb)), address(a), amount, "") {
            ops++;
            calls["flash"]++;
        } catch {}
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function assetsLength() external view returns (uint256) {
        return assets.length;
    }
}
