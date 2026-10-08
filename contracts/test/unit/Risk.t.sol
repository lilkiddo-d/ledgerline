// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {LLErrors} from "../../src/libraries/LLErrors.sol";
import {MarketClock} from "../../src/risk/MarketClock.sol";
import {OracleAdapter} from "../../src/risk/OracleAdapter.sol";
import {IMarketClock} from "../../src/interfaces/IMarketClock.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract MarketClockTest is BaseTest {
    MarketClock internal c;

    function setUp() public override {
        super.setUp();
        c = d.clock;
    }

    function test_regularSession() public view {
        assertTrue(c.isOpenAt(1791385200)); // Wed 11:00 EDT
        assertFalse(c.isOpenAt(1791406800)); // Wed 17:00 EDT
        assertFalse(c.isOpenAt(1791644400)); // Saturday
        assertTrue(c.isOpenAt(1791385200 - 90 minutes)); // 09:30 EDT exactly
        assertFalse(c.isOpenAt(1791385200 - 91 minutes)); // 09:29
    }

    function test_dstTransitions() public view {
        // 2026-03-08 06:59 UTC -> still EST; 07:00 -> EDT
        assertEq(c.utcOffsetAt(1772953140), -5 hours);
        assertEq(c.utcOffsetAt(1772953200), -4 hours);
        // 2026-11-01 05:59 UTC -> EDT; 06:00 -> EST
        assertEq(c.utcOffsetAt(1793512740), -4 hours);
        assertEq(c.utcOffsetAt(1793512800), -5 hours);
    }

    function test_holidays_and_earlyClose() public {
        assertFalse(c.isOpenAt(1795705200)); // Thanksgiving 2026, 10:00 EST
        assertTrue(c.isOpenAt(1795800600)); // Fri 2026-11-27 12:30 EST
        assertFalse(c.isOpenAt(1795804200)); // 13:30 EST after early close
        assertEq(c.dateKey(c.daysFromCivil(2026, 11, 26)), 20261126);
        uint32[] memory dates = new uint32[](1);
        dates[0] = 20261007;
        c.setHolidays(dates, true);
        assertFalse(c.isMarketOpen());
        c.setHolidays(dates, false);
        assertTrue(c.isMarketOpen());
    }

    function test_civilRoundTrip(uint256 day) public view {
        day = bound(day, 0, 200_000);
        (uint256 y, uint256 m, uint256 dd) = c.civilFromDays(day);
        assertEq(c.daysFromCivil(y, m, dd), day);
    }

    function test_forcedClosed_roles() public {
        vm.prank(guardian);
        c.setForcedClosed(true);
        assertFalse(c.isMarketOpen());
        vm.prank(guardian);
        vm.expectRevert();
        c.setForcedClosed(false);
        c.setForcedClosed(false);
        assertTrue(c.isMarketOpen());
        vm.prank(alice);
        vm.expectRevert();
        c.setForcedClosed(true);
    }

    function test_setSchedule() public {
        c.setSchedule(-5 hours, false, 0, 1440, 0x7F); // 24/7
        assertTrue(c.isOpenAt(WEEKEND_TS));
        assertEq(c.utcOffsetAt(OPEN_TS), -5 hours);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        c.setSchedule(-15 hours, true, 0, 1, 1);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        c.setSchedule(0, true, 10, 5, 1);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        c.setSchedule(0, true, 0, 1441, 1);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        c.setSchedule(0, true, 0, 10, 0x80);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        c.setEarlyClose(20261127, 1500);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        c.setEarlyClose(20261327, 100);
        uint32[] memory many = new uint32[](65);
        vm.expectRevert(LLErrors.InvalidParams.selector);
        c.setHolidays(many, true);
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new MarketClock(address(0), guardian);
    }
}

contract OracleAdapterTest is BaseTest {
    OracleAdapter internal o;

    function setUp() public override {
        super.setUp();
        o = d.oracle;
    }

    function _cfg(address primary, address secondary) internal pure returns (OracleAdapter.FeedConfig memory) {
        return OracleAdapter.FeedConfig(primary, secondary, 1 hours, 3 days, 200, true, 1e16, 0);
    }

    function test_basicPrice_scaling() public {
        assertEq(o.getPrice(address(aapl)), 200e18);
        assertEq(o.getPrice(address(usdg)), 1e18);
        MockAggregator f20 = new MockAggregator(20, 5e20);
        o.setFeed(address(nvda), _cfg(address(f20), address(0)));
        assertEq(o.getPrice(address(nvda)), 5e18);
        assertEq(o.getFeed(address(nvda)).primary, address(f20));
    }

    function test_staleness_dependsOnMarketHours() public {
        o.setFeed(address(aapl), _cfg(address(aaplFeed), address(0)));
        vm.warp(block.timestamp + 2 hours); // still open (13:00 EDT), 2h > 1h
        vm.expectRevert(LLErrors.StalePrice.selector);
        o.getPrice(address(aapl));
        vm.warp(WEEKEND_TS); // closed: 3 days allowed; feed is ~2.99 days old
        assertEq(o.getPrice(address(aapl)), 200e18);
        vm.warp(WEEKEND_TS + 1 days);
        vm.expectRevert(LLErrors.StalePrice.selector);
        o.getPrice(address(aapl));
    }

    function test_invalidRounds() public {
        aaplFeed.set(0);
        vm.expectRevert(LLErrors.StalePrice.selector);
        o.getPrice(address(aapl));
        aaplFeed.set(200e8);
        aaplFeed.setRounds(5, 4);
        vm.expectRevert(LLErrors.StalePrice.selector);
        o.getPrice(address(aapl));
        aaplFeed.setRounds(5, 5);
        aaplFeed.setUpdatedAt(block.timestamp + 1);
        vm.expectRevert(LLErrors.StalePrice.selector);
        o.getPrice(address(aapl));
        aaplFeed.setBroken(true);
        vm.expectRevert(LLErrors.StalePrice.selector);
        o.getPrice(address(aapl));
    }

    function test_secondary_deviationAndFallback() public {
        MockAggregator sec = new MockAggregator(8, 201e8);
        o.setFeed(address(aapl), _cfg(address(aaplFeed), address(sec)));
        assertEq(o.getPrice(address(aapl)), 200e18); // 0.5% < 2%
        sec.set(210e8);
        vm.expectRevert(LLErrors.PriceDeviation.selector);
        o.getPrice(address(aapl));
        aaplFeed.setBroken(true);
        assertEq(o.getPrice(address(aapl)), 210e18); // fallback to secondary
        aaplFeed.setBroken(false);
        sec.setBroken(true);
        assertEq(o.getPrice(address(aapl)), 200e18); // fallback to primary
        aaplFeed.setBroken(true);
        vm.expectRevert(LLErrors.StalePrice.selector);
        o.getPrice(address(aapl));
    }

    function test_sanityBand_and_tokenOraclePause() public {
        OracleAdapter.FeedConfig memory c = _cfg(address(aaplFeed), address(0));
        c.maxPrice = 150e18;
        o.setFeed(address(aapl), c);
        vm.expectRevert(LLErrors.InvalidPrice.selector);
        o.getPrice(address(aapl));
        c.maxPrice = 0;
        o.setFeed(address(aapl), c);
        aapl.setOraclePaused(true);
        vm.expectRevert(LLErrors.StalePrice.selector);
        o.getPrice(address(aapl));
        // a token without oraclePaused() is fine (try/catch)
        o.setFeed(address(usdg), c);
        assertEq(o.getPrice(address(usdg)), 200e18);
    }

    function test_sequencerFeed() public {
        MockAggregator seq = new MockAggregator(0, 0);
        o.setSequencerFeed(address(seq), 1 hours);
        vm.expectRevert(LLErrors.SequencerDown.selector); // within grace period
        o.getPrice(address(usdg));
        vm.warp(block.timestamp + 2 hours);
        _refreshFeeds();
        seq.setUpdatedAt(block.timestamp - 2 hours);
        assertEq(o.getPrice(address(usdg)), 1e18);
        seq.set(1); // down
        vm.expectRevert(LLErrors.SequencerDown.selector);
        o.getPrice(address(usdg));
        vm.expectRevert(LLErrors.InvalidParams.selector);
        o.setSequencerFeed(address(seq), 2 days);
    }

    function test_admin_validation() public {
        vm.expectRevert(LLErrors.FeedNotSet.selector);
        o.getPrice(address(0xbeef));
        OracleAdapter.FeedConfig memory c = _cfg(address(0), address(0));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        o.setFeed(address(aapl), c);
        c = _cfg(address(aaplFeed), address(0));
        c.maxAgeOpen = 0;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        o.setFeed(address(aapl), c);
        c = _cfg(address(aaplFeed), address(0));
        c.maxAgeClosed = 8 days;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        o.setFeed(address(aapl), c);
        c = _cfg(address(aaplFeed), address(1));
        c.maxDeviationBps = 0;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        o.setFeed(address(aapl), c);
        c = _cfg(address(aaplFeed), address(0));
        c.maxPrice = 1;
        vm.expectRevert(LLErrors.InvalidParams.selector);
        o.setFeed(address(aapl), c);
        o.setClock(IMarketClock(address(0)));
        assertEq(address(o.clock()), address(0));
        vm.expectRevert(LLErrors.ZeroAddress.selector);
        new OracleAdapter(address(0), IMarketClock(address(0)));
        vm.prank(alice);
        vm.expectRevert();
        o.setFeed(address(aapl), _cfg(address(aaplFeed), address(0)));
    }
}
