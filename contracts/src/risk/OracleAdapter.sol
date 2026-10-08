// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";

/// @notice Optional pause flag exposed by Robinhood Chain stock tokens while corporate actions settle.
interface IOraclePausable {
    function oraclePaused() external view returns (bool);
}

/// @title OracleAdapter
/// @notice Chainlink-compatible price adapter with staleness, sanity-band and cross-source deviation
///         checks. The Pool talks only to IPriceOracle, so this whole contract is swappable via the
///         Timelock (e.g. for a Data Streams or multi-oracle median adapter).
/// @dev Robinhood Chain stock feeds are 24/5 and stop heartbeating off-hours, so the allowed age
///      depends on the MarketClock: `maxAgeOpen` while open, `maxAgeClosed` while closed. Stock
///      tokens expose `oraclePaused()` during splits; when set the price is refused.
contract OracleAdapter is IPriceOracle, AccessControl {
    using MathLib for uint256;

    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");
    uint256 public constant MAX_AGE_LIMIT = 7 days;

    struct FeedConfig {
        address primary;
        address secondary; // optional, zero = none
        uint32 maxAgeOpen;
        uint32 maxAgeClosed;
        uint16 maxDeviationBps; // primary vs secondary
        bool checkTokenOraclePause;
        uint128 minPrice; // WAD sanity band
        uint128 maxPrice; // WAD sanity band, 0 = unbounded
    }

    IMarketClock public clock;
    /// @notice optional L2 sequencer uptime feed (none exists on Robinhood Chain today)
    address public sequencerFeed;
    uint32 public sequencerGracePeriod = 1 hours;
    mapping(address => FeedConfig) private _feeds;

    event FeedSet(address indexed asset, FeedConfig config);
    event ClockSet(address clock);
    event SequencerFeedSet(address feed, uint32 gracePeriod);

    constructor(address admin, IMarketClock clock_) {
        if (admin == address(0)) revert LLErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ADMIN_ROLE, admin);
        clock = clock_;
        emit ClockSet(address(clock_));
    }

    function setFeed(address asset, FeedConfig calldata c) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (asset == address(0) || c.primary == address(0)) revert LLErrors.ZeroAddress();
        if (c.maxAgeOpen == 0 || c.maxAgeClosed < c.maxAgeOpen || c.maxAgeClosed > MAX_AGE_LIMIT) {
            revert LLErrors.InvalidParams();
        }
        if (c.secondary != address(0) && (c.maxDeviationBps == 0 || c.maxDeviationBps > MathLib.BPS)) {
            revert LLErrors.InvalidParams();
        }
        if (c.maxPrice != 0 && c.maxPrice <= c.minPrice) revert LLErrors.InvalidParams();
        _feeds[asset] = c;
        emit FeedSet(asset, c);
    }

    function setClock(IMarketClock clock_) external onlyRole(ORACLE_ADMIN_ROLE) {
        clock = clock_;
        emit ClockSet(address(clock_));
    }

    function setSequencerFeed(address feed, uint32 gracePeriod) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (gracePeriod > 1 days) revert LLErrors.InvalidParams();
        sequencerFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    function getFeed(address asset) external view returns (FeedConfig memory) {
        return _feeds[asset];
    }

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256 price) {
        FeedConfig memory c = _feeds[asset];
        if (c.primary == address(0)) revert LLErrors.FeedNotSet();
        _checkSequencer();
        if (c.checkTokenOraclePause) {
            try IOraclePausable(asset).oraclePaused() returns (bool paused) {
                if (paused) revert LLErrors.StalePrice();
            } catch {}
        }
        address clk = address(clock);
        uint256 maxAge = clk == address(0) || IMarketClock(clk).isMarketOpen() ? c.maxAgeOpen : c.maxAgeClosed;

        (bool ok1, uint256 p1) = _read(c.primary, maxAge);
        if (c.secondary == address(0)) {
            if (!ok1) revert LLErrors.StalePrice();
            price = p1;
        } else {
            (bool ok2, uint256 p2) = _read(c.secondary, maxAge);
            if (ok1 && ok2) {
                uint256 diff = p1 > p2 ? p1 - p2 : p2 - p1;
                if (diff.mulDivUp(MathLib.BPS, p2) > c.maxDeviationBps) revert LLErrors.PriceDeviation();
                price = p1;
            } else if (ok1) {
                price = p1;
            } else if (ok2) {
                price = p2;
            } else {
                revert LLErrors.StalePrice();
            }
        }
        if (price < c.minPrice || (c.maxPrice != 0 && price > c.maxPrice)) revert LLErrors.InvalidPrice();
    }

    // startedAt is irrelevant for staleness; updatedAt/answeredInRound are checked.
    // slither-disable-start unused-return
    /// @dev Returns (false, 0) instead of reverting so a broken secondary can fall back cleanly.
    function _read(address feed, uint256 maxAge) private view returns (bool, uint256) {
        try IAggregatorV3(feed).latestRoundData() returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) {
                return (false, 0);
            }
            if (block.timestamp - updatedAt > maxAge) return (false, 0);
            uint8 dec = IAggregatorV3(feed).decimals();
            uint256 a = uint256(answer);
            return (true, dec <= 18 ? a * 10 ** (18 - dec) : a / 10 ** (dec - 18));
        } catch {
            return (false, 0);
        }
    }
    // slither-disable-end unused-return

    function _checkSequencer() private view {
        address f = sequencerFeed;
        if (f == address(0)) return;
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(f).latestRoundData();
        // answer == 0: up, 1: down. startedAt == 0 signals an uninitialized round on some L2s.
        if (answer != 0 || startedAt == 0 || updatedAt < startedAt || answeredInRound < roundId) {
            revert LLErrors.SequencerDown();
        }
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert LLErrors.SequencerDown();
    }
}
