// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {LLErrors} from "../../src/libraries/LLErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {FeeCollector} from "../../src/treasury/FeeCollector.sol";
import {Reserve} from "../../src/treasury/Reserve.sol";
import {ProjectTokenHooks} from "../../src/token/ProjectTokenHooks.sol";
import {Timelock} from "../../src/governance/Timelock.sol";
import {ComplianceRegistry} from "../../src/compliance/ComplianceRegistry.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IProjectTokenHooks} from "../../src/interfaces/IProjectTokenHooks.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeCollectorTest is BaseTest {
    MockSwapAdapter internal swap;

    function setUp() public override {
        super.setUp();
        swap = new MockSwapAdapter();
        d.feeCollector.grantRole(d.feeCollector.KEEPER_ROLE(), keeper);
        d.feeCollector.setConfig(
            address(d.reserve), treasury, IProjectTokenHooks(address(d.hooks)), ISwapAdapter(address(swap)), IPriceOracle(address(d.oracle))
        );
    }

    function _generateFees() internal {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 100e18);
        _borrow(bob, usdg, 8_000e6);
        _warpBy(365 days);
    }

    function test_harvest_and_distribute_tokenInactive() public {
        _generateFees();
        uint256 got = d.feeCollector.harvest(address(usdg));
        assertGt(got, 0);
        d.feeCollector.distribute(address(usdg));
        // token inactive: 20% reserve, 80% treasury, 0 stakers
        assertApproxEqAbs(usdg.balanceOf(address(d.reserve)), got * 2 / 10, 1);
        assertApproxEqAbs(usdg.balanceOf(treasury), got * 8 / 10, 1);
        assertEq(usdg.balanceOf(address(d.hooks)), 0);
        d.feeCollector.distribute(address(usdg)); // empty no-op
        assertEq(d.feeCollector.harvest(address(usdg)), 0); // nothing new
    }

    function test_harvest_limitedByCash() public {
        _supply(alice, usdg, 10_000e6);
        _supply(bob, aapl, 1_000e18);
        _borrow(bob, usdg, 10_000e6); // 100% utilization
        _warpBy(30 days);
        assertEq(d.feeCollector.harvest(address(usdg)), 0); // no cash to redeem
    }

    function test_swapToStable_slippageAndDeadline() public {
        aapl.mint(address(d.feeCollector), 1e18); // worth $200
        swap.setRate(199e6); // 199 USDG per AAPL
        vm.startPrank(keeper);
        vm.expectRevert(LLErrors.DeadlineExpired.selector);
        d.feeCollector.swapToStable(address(aapl), 1e18, 199e6, block.timestamp - 1);
        vm.expectRevert(LLErrors.SlippageTooHigh.selector);
        d.feeCollector.swapToStable(address(aapl), 1e18, 190e6, block.timestamp); // > 1% below oracle
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.feeCollector.swapToStable(address(usdg), 1, 1, block.timestamp);
        uint256 out = d.feeCollector.swapToStable(address(aapl), 1e18, 198e6, block.timestamp);
        vm.stopPrank();
        assertEq(out, 199e6);
        vm.prank(alice);
        vm.expectRevert();
        d.feeCollector.swapToStable(address(aapl), 1, 1, block.timestamp);
    }

    function test_distribute_nonStable_noStakerShare() public {
        aapl.mint(address(d.feeCollector), 10e18);
        d.feeCollector.distribute(address(aapl));
        assertEq(aapl.balanceOf(address(d.reserve)), 2e18);
        assertEq(aapl.balanceOf(treasury), 8e18);
    }

    function test_admin() public {
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.feeCollector.setShares(6_000, 5_000, 100);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        d.feeCollector.setShares(1_000, 1_000, 600);
        d.feeCollector.setShares(1_000, 1_000, 50);
        assertEq(d.feeCollector.maxSlippageBps(), 50);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.feeCollector.setConfig(address(0), treasury, IProjectTokenHooks(address(0)), ISwapAdapter(address(0)), IPriceOracle(address(0)));
        d.feeCollector.setConfig(address(d.reserve), treasury, IProjectTokenHooks(address(0)), ISwapAdapter(address(0)), IPriceOracle(address(0)));
        vm.prank(keeper);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.feeCollector.swapToStable(address(aapl), 1, 1, block.timestamp);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new FeeCollector(address(0), IPool(address(d.pool)), address(usdg), address(1), address(1), IPriceOracle(address(0)));
    }
}

contract ReserveTest is BaseTest {
    function test_reserve() public {
        usdg.mint(address(d.reserve), 100e6);
        vm.expectRevert(LLErrors.OnlyPool.selector);
        d.reserve.coverBadDebt(address(usdg), 1);
        vm.prank(address(d.pool));
        assertEq(d.reserve.coverBadDebt(address(usdg), 150e6), 100e6);
        vm.prank(address(d.pool));
        assertEq(d.reserve.coverBadDebt(address(usdg), 1), 0);
        usdg.mint(address(d.reserve), 5e6);
        vm.expectRevert(); // admin is the timelock
        d.reserve.withdraw(address(usdg), alice, 5e6);
        vm.prank(address(d.timelock));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        d.reserve.withdraw(address(usdg), address(0), 5e6);
        vm.prank(address(d.timelock));
        d.reserve.withdraw(address(usdg), alice, 5e6);
        assertEq(usdg.balanceOf(alice), 5e6);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new Reserve(address(0), address(1));
    }
}

contract ProjectTokenHooksTest is BaseTest {
    MockERC20 internal ledg; // test-only mock; the real token launches separately
    ProjectTokenHooks internal h;

    function setUp() public override {
        super.setUp();
        h = d.hooks;
        ledg = new MockERC20("Ledgerline", "LEDG", 18);
    }

    function _activate() internal {
        vm.prank(address(d.timelock));
        h.setProjectToken(address(ledg));
    }

    function _stake(address u, uint256 amt) internal {
        ledg.mint(u, amt);
        vm.startPrank(u);
        ledg.approve(address(h), amt);
        h.stake(amt);
        vm.stopPrank();
    }

    function test_inactiveByDefault() public {
        assertFalse(h.isActive());
        assertEq(h.borrowDiscountBps(alice), 0);
        vm.expectRevert(LLErrors.NotActive.selector);
        h.stake(1);
        vm.expectRevert(LLErrors.NotActive.selector);
        h.requestUnstake(1);
        vm.expectRevert(LLErrors.NotActive.selector);
        h.withdrawUnstaked();
        assertEq(h.tiers().length, 3);
    }

    function test_setProjectToken_onceByOwnerOnly() public {
        vm.expectRevert();
        h.setProjectToken(address(ledg));
        vm.startPrank(address(d.timelock));
        vm.expectRevert(LLErrors.InvalidParams.selector);
        h.setProjectToken(address(0));
        vm.expectRevert(LLErrors.InvalidParams.selector);
        h.setProjectToken(address(0x1234)); // no code
        vm.expectRevert(LLErrors.InvalidParams.selector);
        h.setProjectToken(address(usdg));
        h.setProjectToken(address(ledg));
        vm.expectRevert(LLErrors.AlreadySet.selector);
        h.setProjectToken(address(ledg));
        vm.stopPrank();
        assertTrue(h.isActive());
    }

    function test_staking_rewards_flow() public {
        _activate();
        // reward arrives before anyone staked -> queued
        usdg.mint(address(d.feeCollector), 100e6);
        d.feeCollector.distribute(address(usdg));
        assertEq(h.queuedRewards(), 30e6);

        _stake(alice, 1_000e18);
        _stake(bob, 3_000e18);
        assertEq(h.earned(alice), 30e6); // queued flushed to first staker
        usdg.mint(address(d.feeCollector), 1_000e6);
        d.feeCollector.distribute(address(usdg));
        assertApproxEqAbs(h.earned(alice), 30e6 + 75e6, 1);
        assertApproxEqAbs(h.earned(bob), 225e6, 1);
        vm.prank(alice);
        uint256 c = h.claim();
        assertEq(usdg.balanceOf(alice), c);
        vm.prank(alice);
        assertEq(h.claim(), 0);

        // unstake cooldown
        vm.startPrank(bob);
        vm.expectRevert(LLErrors.InsufficientBalance.selector);
        h.requestUnstake(4_000e18);
        h.requestUnstake(3_000e18);
        assertEq(h.borrowDiscountBps(bob), 0);
        vm.expectRevert(LLErrors.Cooldown.selector);
        h.withdrawUnstaked();
        vm.warp(block.timestamp + 7 days);
        h.withdrawUnstaked();
        vm.expectRevert(LLErrors.ZeroAmount.selector);
        h.withdrawUnstaked();
        vm.stopPrank();
        assertEq(ledg.balanceOf(bob), 3_000e18);
        vm.expectRevert(LLErrors.OnlyPool.selector);
        h.notifyReward(1);
        vm.expectRevert(LLErrors.ZeroAmount.selector);
        h.stake(0);
    }

    function test_tiers() public {
        _activate();
        _stake(alice, 10_000e18);
        assertEq(h.borrowDiscountBps(alice), 2_500);
        uint128[] memory m = new uint128[](1);
        uint16[] memory b = new uint16[](1);
        m[0] = 1e18;
        b[0] = 4_000;
        vm.prank(address(d.timelock));
        h.setTiers(m, b);
        assertEq(h.borrowDiscountBps(alice), 4_000);
        b[0] = 6_000;
        vm.prank(address(d.timelock));
        vm.expectRevert(LLErrors.InvalidParams.selector);
        h.setTiers(m, b);
        uint128[] memory m2 = new uint128[](2);
        uint16[] memory b2 = new uint16[](2);
        (m2[0], m2[1], b2[0], b2[1]) = (10, 5, 1, 2);
        vm.prank(address(d.timelock));
        vm.expectRevert(LLErrors.InvalidParams.selector);
        h.setTiers(m2, b2);
        vm.prank(address(d.timelock));
        vm.expectRevert(LLErrors.InvalidParams.selector);
        h.setCooldown(1 hours);
        vm.prank(address(d.timelock));
        h.setCooldown(3 days);
        assertEq(h.cooldown(), 3 days);
    }

    function test_borrowDiscount_endToEnd() public {
        _activate();
        _supply(alice, usdg, 100_000e6);
        _supply(bob, aapl, 100e18);
        _supply(carol, aapl, 100e18);
        _stake(bob, 100_000e18); // 50% discount on protocol share
        _borrow(bob, usdg, 10_000e6);
        _borrow(carol, usdg, 10_000e6);
        _warpBy(365 days);
        // touch both positions
        usdg.mint(bob, 1);
        usdg.mint(carol, 1);
        vm.prank(bob);
        d.pool.repay(address(usdg), 1, bob);
        vm.prank(carol);
        d.pool.repay(address(usdg), 1, carol);
        uint256 debtBob = _dt(address(usdg)).balanceOf(bob);
        uint256 debtCarol = _dt(address(usdg)).balanceOf(carol);
        uint256 interest = debtCarol - 10_000e6;
        // bob saves ~ interest * 10% reserve factor * 50%
        assertApproxEqRel(debtCarol - debtBob, interest / 20, 0.02e18);
        // suppliers unaffected: solvency still holds
        assertGe(d.pool.getReserveData(address(usdg)).cash + d.pool.totalDebt(address(usdg)), d.pool.totalSupplyAssets(address(usdg)));
    }

    function test_constructor() public {
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new ProjectTokenHooks(address(this), IERC20(address(0)), address(1));
    }
}

contract GovernanceTest is BaseTest {
    function test_handover_removesDeployer() public {
        _handover(d, cfg);
        bytes32 admin = 0x00;
        assertFalse(d.pool.hasRole(admin, address(this)));
        assertTrue(d.pool.hasRole(admin, address(d.timelock)));
        assertFalse(d.assetConfig.hasRole(d.assetConfig.RISK_ADMIN_ROLE(), address(this)));
        assertTrue(d.assetConfig.hasRole(d.assetConfig.RISK_ADMIN_ROLE(), address(d.timelock)));
        assertFalse(d.oracle.hasRole(d.oracle.ORACLE_ADMIN_ROLE(), address(this)));
        assertFalse(d.clock.hasRole(d.clock.CLOCK_ADMIN_ROLE(), address(this)));
        assertFalse(d.compliance.hasRole(admin, address(this)));
        assertFalse(d.feeCollector.hasRole(admin, address(this)));
        assertTrue(d.feeCollector.hasRole(d.feeCollector.KEEPER_ROLE(), keeper));
        assertEq(d.hooks.owner(), address(d.timelock));
        vm.expectRevert();
        d.pool.setFlashFeeBps(1);
    }

    function test_timelock_setProjectToken_after48h() public {
        _handover(d, cfg);
        MockERC20 ledg = new MockERC20("Ledgerline", "LEDG", 18);
        bytes memory data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(ledg)));
        vm.prank(gov);
        vm.expectRevert(); // below min delay
        d.timelock.schedule(address(d.hooks), 0, data, bytes32(0), bytes32(0), 1 days);
        vm.prank(gov);
        d.timelock.schedule(address(d.hooks), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.prank(gov);
        vm.expectRevert();
        d.timelock.execute(address(d.hooks), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(gov);
        d.timelock.execute(address(d.hooks), 0, data, bytes32(0), bytes32(0));
        assertTrue(d.hooks.isActive());
    }

    function test_timelock_floor() public {
        address[] memory a = new address[](1);
        a[0] = gov;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        new Timelock(1 days, a, a);
        assertEq(d.timelock.getMinDelay(), 48 hours);
        // even if governance lowers the stored delay, the floor holds
        vm.prank(address(d.timelock));
        d.timelock.updateDelay(1 hours);
        assertEq(d.timelock.getMinDelay(), 48 hours);
    }

    function test_compliance_registry() public {
        ComplianceRegistry c = d.compliance;
        assertTrue(c.isAllowed(alice, 1));
        c.setEnabled(true);
        assertFalse(c.isAllowed(alice, 1));
        address[] memory many = new address[](201);
        vm.prank(gov);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        c.setAllowed(many, true);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new ComplianceRegistry(address(0), address(1));
    }
}
