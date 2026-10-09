// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

import {RobinhoodDeployment} from "../../script/RobinhoodDeployment.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {LLErrors} from "../../src/libraries/LLErrors.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";

/// @notice Runs the production deployment path (RobinhoodDeployment, shared with Deploy.s.sol) against a fork of Robinhood Chain mainnet and
///         exercises the protocol with the real USDG, stock tokens and Chainlink feeds.
///         Requires ROBINHOOD_RPC_URL (mainnet RPC or a local anvil fork of it); skipped otherwise.
contract RobinhoodForkTest is Test, RobinhoodDeployment {
    Deployment internal d;
    address internal alice = makeAddr("fork-alice");
    address internal bob = makeAddr("fork-bob");
    address internal liq = makeAddr("fork-liquidator");
    bool internal noFork;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            noFork = true;
            return;
        }
        vm.createSelectFork(rpc);
        _preflight();
        address gov = makeAddr("fork-governance");
        Config memory c = Config(address(this), gov, gov, gov, gov, RH.USDG, 48 hours);
        d = _deployRobinhood(c);
        _postflight(d, address(this));
    }

    modifier onlyFork() {
        if (noFork) {
            vm.skip(true);
        }
        _;
    }

    function _fund(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
        assertEq(IERC20(token).balanceOf(to), amount, "deal failed");
        vm.prank(to);
        IERC20(token).approve(address(d.pool), type(uint256).max);
    }

    function _price(address feed) internal view returns (uint256) {
        (, int256 a,,,) = IAggregatorV3(feed).latestRoundData();
        return uint256(a) * 1e10;
    }

    function test_fork_deploymentWiring() public onlyFork {
        assertEq(d.pool.getReservesList().length, 10);
        assertEq(d.timelock.getMinDelay(), 48 hours);
        assertFalse(d.hooks.isActive());
        assertFalse(d.compliance.enabled());
        // live oracle prices pass all adapter checks
        assertEq(d.oracle.getPrice(RH.AAPL), _price(RH.AAPL_FEED));
        assertEq(d.oracle.getPrice(RH.USDG), _price(RH.USDG_USD_FEED));
        assertGt(d.oracle.getPrice(RH.TSLA), 1e18);
    }

    function test_fork_supplyBorrowRepayWithdraw_realTokens() public onlyFork {
        _fund(RH.USDG, alice, 1_000_000e6);
        _fund(RH.AAPL, bob, 100e18);
        vm.prank(alice);
        d.pool.supply(RH.USDG, 1_000_000e6, alice);
        vm.prank(bob);
        d.pool.supply(RH.AAPL, 100e18, bob);

        Types.AccountData memory a = d.pool.getUserAccountData(bob);
        uint256 borrowUsd = a.borrowPowerUsd / 2; // stay well inside, works in open or closed session
        uint256 borrowAmt = borrowUsd * 1e6 / d.oracle.getPrice(RH.USDG);
        vm.prank(bob);
        d.pool.borrow(RH.USDG, borrowAmt);
        assertEq(IERC20(RH.USDG).balanceOf(bob), borrowAmt);
        assertGt(d.pool.getUserAccountData(bob).healthFactor, 1e18);

        vm.warp(block.timestamp + 1 days);
        _mockFresh();
        deal(RH.USDG, bob, borrowAmt * 2);
        vm.prank(bob);
        IERC20(RH.USDG).approve(address(d.pool), type(uint256).max);
        vm.prank(bob);
        uint256 repaid = d.pool.repay(RH.USDG, type(uint256).max, bob);
        assertGt(repaid, borrowAmt); // interest accrued
        vm.prank(bob);
        d.pool.withdraw(RH.AAPL, type(uint256).max, bob);
        assertEq(IERC20(RH.AAPL).balanceOf(bob), 100e18);
    }

    function test_fork_shortStock_and_liquidate() public onlyFork {
        _fund(RH.NVDA, alice, 1_000e18);
        _fund(RH.USDG, bob, 100_000e6);
        vm.prank(alice);
        d.pool.supply(RH.NVDA, 1_000e18, alice);
        vm.prank(bob);
        d.pool.supply(RH.USDG, 100_000e6, bob);

        uint256 nvda = d.oracle.getPrice(RH.NVDA);
        uint256 power = d.pool.getUserAccountData(bob).borrowPowerUsd;
        uint256 shortAmt = power * 9 / 10 * 1e18 / nvda;
        vm.prank(bob);
        d.pool.borrow(RH.NVDA, shortAmt);

        // NVDA rallies 30%: short is underwater
        (uint80 r, int256 ans,, uint256 upd, uint80 air) = IAggregatorV3(RH.NVDA_FEED).latestRoundData();
        vm.mockCall(
            RH.NVDA_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(r, ans * 130 / 100, upd, upd, air)
        );
        assertLt(d.pool.getUserAccountData(bob).healthFactor, 1e18);

        _fund(RH.NVDA, liq, shortAmt);
        vm.prank(liq);
        (uint256 repaid, uint256 seized) = d.pool.liquidate(RH.USDG, RH.NVDA, bob, type(uint256).max, false);
        assertGt(repaid, 0);
        assertEq(IERC20(RH.USDG).balanceOf(liq), seized - (seized - seized * 10_000 / 10_500) / 10);
    }

    function test_fork_flashLoan_realUSDG() public onlyFork {
        _fund(RH.USDG, alice, 500_000e6);
        vm.prank(alice);
        d.pool.supply(RH.USDG, 500_000e6, alice);
        MockFlashBorrower fb = new MockFlashBorrower(address(d.pool));
        deal(RH.USDG, address(fb), 1_000e6);
        d.pool.flashLoan(IERC3156FlashBorrower(address(fb)), RH.USDG, 400_000e6, "");
        assertEq(d.pool.getReserveData(RH.USDG).cash, 500_000e6 + 200e6);
    }

    function test_fork_unhealthyCannotBeHealthyLiquidated() public onlyFork {
        _fund(RH.USDG, alice, 100_000e6);
        _fund(RH.MSFT, bob, 10e18);
        vm.prank(alice);
        d.pool.supply(RH.USDG, 100_000e6, alice);
        vm.prank(bob);
        d.pool.supply(RH.MSFT, 10e18, bob);
        vm.prank(bob);
        d.pool.borrow(RH.USDG, 100e6);
        _fund(RH.USDG, liq, 100e6);
        vm.prank(liq);
        vm.expectRevert(LLErrors.HealthyAccount.selector);
        d.pool.liquidate(RH.MSFT, RH.USDG, bob, 50e6, false);
    }

    /// @dev Keep every feed's updatedAt fresh after a warp (feeds don't heartbeat off-hours).
    function _mockFresh() internal {
        address[2] memory feeds = [RH.USDG_USD_FEED, RH.AAPL_FEED];
        vm.clearMockedCalls();
        for (uint256 i; i < feeds.length; ++i) {
            (uint80 r, int256 a,,, uint80 air) = IAggregatorV3(feeds[i]).latestRoundData();
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(r, a, block.timestamp, block.timestamp, air)
            );
        }
    }
}
