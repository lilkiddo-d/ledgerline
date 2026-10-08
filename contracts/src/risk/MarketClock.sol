// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";

/// @title MarketClock
/// @notice On-chain US equity session calendar. Weekly schedule (local New York time), holiday and
///         early-close tables keyed by local date (YYYYMMDD), and US daylight-saving rules computed
///         on-chain (2nd Sunday of March -> 1st Sunday of November), so no keeper is needed for DST.
///         The guardian can force the market "closed" (more conservative) instantly; everything that
///         loosens risk goes through the Timelock (CLOCK_ADMIN_ROLE).
contract MarketClock is IMarketClock, AccessControl {
    bytes32 public constant CLOCK_ADMIN_ROLE = keccak256("CLOCK_ADMIN_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 public constant MAX_BATCH = 64;

    int256 public standardOffset = -5 hours; // EST
    bool public dstEnabled = true;
    uint16 public openMinute = 570; // 09:30
    uint16 public closeMinute = 960; // 16:00
    uint8 public tradingDaysMask = 0x3E; // bit0 = Sunday ... bit6 = Saturday -> Mon-Fri
    bool public forcedClosed;

    mapping(uint32 => bool) public isHoliday; // YYYYMMDD local
    mapping(uint32 => uint16) public earlyCloseMinute; // YYYYMMDD local -> close minute

    event ScheduleUpdated(int256 standardOffset, bool dstEnabled, uint16 openMinute, uint16 closeMinute, uint8 daysMask);
    event HolidaySet(uint32 indexed date, bool holiday);
    event EarlyCloseSet(uint32 indexed date, uint16 closeMinute);
    event ForcedClosed(bool closed);

    constructor(address admin, address guardian) {
        if (admin == address(0) || guardian == address(0)) revert LLErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CLOCK_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ---------------- admin ----------------

    function setSchedule(int256 stdOffset, bool dst, uint16 open, uint16 close, uint8 daysMask)
        external
        onlyRole(CLOCK_ADMIN_ROLE)
    {
        if (stdOffset < -14 hours || stdOffset > 14 hours || open >= close || close > 1440 || daysMask > 0x7F) {
            revert LLErrors.InvalidParams();
        }
        standardOffset = stdOffset;
        dstEnabled = dst;
        openMinute = open;
        closeMinute = close;
        tradingDaysMask = daysMask;
        emit ScheduleUpdated(stdOffset, dst, open, close, daysMask);
    }

    function setHolidays(uint32[] calldata dates, bool holiday) external onlyRole(CLOCK_ADMIN_ROLE) {
        if (dates.length > MAX_BATCH) revert LLErrors.InvalidParams();
        for (uint256 i; i < dates.length; ++i) {
            _checkDate(dates[i]);
            isHoliday[dates[i]] = holiday;
            emit HolidaySet(dates[i], holiday);
        }
    }

    function setEarlyClose(uint32 date, uint16 minute) external onlyRole(CLOCK_ADMIN_ROLE) {
        _checkDate(date);
        if (minute > 1440) revert LLErrors.InvalidParams();
        earlyCloseMinute[date] = minute;
        emit EarlyCloseSet(date, minute);
    }

    /// @notice Guardian may close the market (e.g. trading halt); only the admin may re-open.
    function setForcedClosed(bool closed) external {
        if (closed) {
            if (!hasRole(GUARDIAN_ROLE, msg.sender)) _checkRole(CLOCK_ADMIN_ROLE);
        } else {
            _checkRole(CLOCK_ADMIN_ROLE);
        }
        forcedClosed = closed;
        emit ForcedClosed(closed);
    }

    // ---------------- views ----------------

    function isMarketOpen() external view returns (bool) {
        return isOpenAt(block.timestamp);
    }

// Calendar arithmetic: `%` derives weekdays/minutes (not randomness) and floor division is required by the date algorithm.
    // slither-disable-start weak-prng,divide-before-multiply
    function isOpenAt(uint256 ts) public view returns (bool) {
        if (forcedClosed) return false;
        uint256 local = uint256(int256(ts) + utcOffsetAt(ts));
        uint256 day = local / 1 days;
        uint256 weekday = (day + 4) % 7; // 1970-01-01 was a Thursday; 0 = Sunday
        if ((tradingDaysMask >> weekday) & 1 == 0) return false;
        uint32 key = dateKey(day);
        if (isHoliday[key]) return false;
        uint256 minute = (local % 1 days) / 60;
        uint256 close = earlyCloseMinute[key] != 0 ? earlyCloseMinute[key] : closeMinute;
        return minute >= openMinute && minute < close;
    }

    /// @notice New York UTC offset in seconds at `ts`, applying US DST rules when enabled.
    function utcOffsetAt(uint256 ts) public view returns (int256) {
        if (!dstEnabled) return standardOffset;
        (uint256 y,,) = civilFromDays(ts / 1 days);
        // DST begins 02:00 local standard time on the 2nd Sunday of March,
        // ends 02:00 local daylight time on the 1st Sunday of November.
        uint256 start = (_firstSunday(y, 3) + 7) * 1 days + uint256(2 hours - standardOffset);
        uint256 end = _firstSunday(y, 11) * 1 days + uint256(1 hours - standardOffset);
        return ts >= start && ts < end ? standardOffset + 1 hours : standardOffset;
    }

    function dateKey(uint256 day) public pure returns (uint32) {
        (uint256 y, uint256 m, uint256 d) = civilFromDays(day);
        return uint32(y * 10_000 + m * 100 + d);
    }

    /// @dev Howard Hinnant's days_from_civil, valid for years >= 1970.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) public pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// @dev Howard Hinnant's civil_from_days.
    function civilFromDays(uint256 z) public pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }

    function _firstSunday(uint256 y, uint256 m) private pure returns (uint256) {
        uint256 first = daysFromCivil(y, m, 1);
        uint256 wd = (first + 4) % 7;
        return first + (7 - wd) % 7;
    }

    function _checkDate(uint32 date) private pure {
        uint256 m = (date / 100) % 100;
        uint256 d = date % 100;
        if (date < 19_700_101 || m == 0 || m > 12 || d == 0 || d > 31) revert LLErrors.InvalidParams();
    }
    // slither-disable-end weak-prng,divide-before-multiply
}
