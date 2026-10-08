// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {Types} from "../libraries/Types.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IAssetConfig} from "../interfaces/IAssetConfig.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {IReserve} from "../interfaces/IReserve.sol";
import {IProjectTokenHooks} from "../interfaces/IProjectTokenHooks.sol";
import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";
import {IReceiptToken, IDebtToken} from "../interfaces/ITokens.sol";

/// @title PoolBase
/// @notice Storage layout and accounting shared by the Pool and its delegatecall modules
///         (LiquidationLogic, FlashLoan). All state lives in one ERC-7201 namespace so the
///         inheritance graph of each contract never affects the layout.
abstract contract PoolBase {
    using MathLib for uint256;

    uint256 internal constant MAX_RESERVES = 32;
    uint256 internal constant CLOSE_FACTOR_BPS = 5_000;
    uint256 internal constant FULL_CLOSE_HF = 0.95e18;
    uint256 internal constant MAX_FLASH_FEE_BPS = 100;
    uint256 internal constant HF_ONE = 1e18;
    uint256 internal constant BORROWING_MASK = 0x5555555555555555555555555555555555555555555555555555555555555555;

    /// @custom:storage-location erc7201:ledgerline.storage.Pool
    struct PoolStorage {
        mapping(address => Types.ReserveData) reserves;
        address[] reservesList;
        mapping(address => uint256) userConfig; // bit 2*id = borrowing, bit 2*id+1 = collateral
        mapping(address => uint8) userEMode;
        IAssetConfig assetConfig;
        IPriceOracle oracle;
        IMarketClock clock;
        IComplianceRegistry compliance;
        IReserve reserve;
        IProjectTokenHooks hooks;
        address feeCollector;
        uint16 flashFeeBps;
    }

    // keccak256(abi.encode(uint256(keccak256("ledgerline.storage.Pool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x62d4a30496b634d5d4b765f35b7f5011852763ee861c4b4e7295665b22b33300;

    function _s() internal pure returns (PoolStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // ------------------------------------------------------------------
    // Reserve state
    // ------------------------------------------------------------------

    function _reserve(address asset) internal view returns (Types.ReserveData storage r) {
        r = _s().reserves[asset];
        if (!r.active) revert LLErrors.ReserveNotActive();
    }

    /// @dev Pure projection of the indices to the current timestamp. Shared by views and `_accrue`
    ///      so that what users see is exactly what accrual writes.
    function _previewIndices(Types.ReserveData storage r, uint256 reserveFactorBps)
        internal
        view
        returns (uint256 liqIndex, uint256 borrowIndex, uint256 treasuryScaled)
    {
        liqIndex = r.liquidityIndex;
        borrowIndex = r.borrowIndex;
        treasuryScaled = r.accruedToTreasuryScaled;
        uint256 dt = block.timestamp - r.lastUpdate;
        if (dt == 0 || r.borrowRateRay == 0) return (liqIndex, borrowIndex, treasuryScaled);

        uint256 scaledDebt = IDebtToken(r.debtToken).scaledTotalSupply();
        // Debt grows linearly within one accrual window and compounds across windows.
        // Rounded up: borrowers never pay less than the model says.
        uint256 newBorrowIndex = borrowIndex + borrowIndex.mulDivUp(uint256(r.borrowRateRay) * dt, MathLib.RAY * MathLib.SECONDS_PER_YEAR);
        if (scaledDebt == 0) return (liqIndex, newBorrowIndex, treasuryScaled);

        uint256 debtAfter = scaledDebt.rayMulDown(newBorrowIndex);
        uint256 debtBefore = scaledDebt.rayMulUp(borrowIndex);
        // Interest credited to suppliers is rounded down: claims never exceed what borrowers owe.
        uint256 interest = debtAfter > debtBefore ? debtAfter - debtBefore : 0;
        uint256 totalShares = IReceiptToken(r.receiptToken).totalSupply() + treasuryScaled;
        if (interest == 0 || totalShares == 0) return (liqIndex, newBorrowIndex, treasuryScaled);

        uint256 toTreasury = interest.bpsMulDown(reserveFactorBps);
        uint256 toSuppliers = interest - toTreasury;
        liqIndex += toSuppliers.mulDivDown(MathLib.RAY, totalShares);
        treasuryScaled += toTreasury.rayDivDown(liqIndex);
        borrowIndex = newBorrowIndex;
    }

    function _accrue(address asset, Types.ReserveData storage r) internal {
        if (r.lastUpdate == block.timestamp) return;
        uint256 rf = _s().assetConfig.getRiskParams(asset).reserveFactorBps;
        (uint256 li, uint256 bi, uint256 ts) = _previewIndices(r, rf);
        r.liquidityIndex = uint128(li);
        r.borrowIndex = uint128(bi);
        r.accruedToTreasuryScaled = uint128(ts);
        r.lastUpdate = uint40(block.timestamp);
        emit IPool.ReserveAccrued(asset, li, bi, r.borrowRateRay);
    }

    function _updateRate(address asset, Types.ReserveData storage r) internal {
        address irm = _s().assetConfig.interestRateModel(asset);
        uint256 debt = IDebtToken(r.debtToken).scaledTotalSupply().rayMulDown(r.borrowIndex);
        r.borrowRateRay = uint128(IInterestRateModel(irm).getBorrowRate(r.cash, debt));
    }

    function _totalDebtOf(Types.ReserveData storage r) internal view returns (uint256) {
        return IDebtToken(r.debtToken).scaledTotalSupply().rayMulUp(r.borrowIndex);
    }

    function _totalSupplyOf(Types.ReserveData storage r) internal view returns (uint256) {
        return (IReceiptToken(r.receiptToken).totalSupply() + r.accruedToTreasuryScaled).rayMulDown(r.liquidityIndex);
    }

    // ------------------------------------------------------------------
    // User configuration bitmap
    // ------------------------------------------------------------------

    function _isBorrowing(uint256 cfg, uint256 id) internal pure returns (bool) {
        return (cfg >> (id * 2)) & 1 == 1;
    }

    function _isCollateral(uint256 cfg, uint256 id) internal pure returns (bool) {
        return (cfg >> (id * 2 + 1)) & 1 == 1;
    }

    function _setBorrowing(address user, uint256 id, bool on) internal {
        uint256 bit = 1 << (id * 2);
        PoolStorage storage $ = _s();
        $.userConfig[user] = on ? $.userConfig[user] | bit : $.userConfig[user] & ~bit;
    }

    function _setCollateral(address user, uint256 id, bool on) internal {
        uint256 bit = 1 << (id * 2 + 1);
        PoolStorage storage $ = _s();
        $.userConfig[user] = on ? $.userConfig[user] | bit : $.userConfig[user] & ~bit;
    }

    // ------------------------------------------------------------------
    // Risk
    // ------------------------------------------------------------------

    function _marketOpen() internal view returns (bool) {
        IMarketClock c = _s().clock;
        return address(c) == address(0) || c.isMarketOpen();
    }

    /// @dev Applies e-mode and the closed-market LTV cap.
    function _effectiveParams(Types.RiskParams memory p, uint8 userEMode, bool open)
        internal
        view
        returns (uint256 ltv, uint256 lt, uint256 bonus)
    {
        ltv = p.collateralEnabled ? p.ltvBps : 0;
        lt = p.liqThresholdBps;
        bonus = p.liqBonusBps;
        if (userEMode != 0 && p.eModeCategory == userEMode) {
            Types.EModeCategory memory e = _s().assetConfig.getEModeCategory(userEMode);
            if (p.collateralEnabled) ltv = e.ltvBps;
            lt = e.liqThresholdBps;
            bonus = e.liqBonusBps;
        }
        if (p.isStock && !open && ltv > p.closedLtvBps) ltv = p.closedLtvBps;
    }

    function _valueUsd(uint256 amount, uint256 priceWad, uint8 decimals) internal pure returns (uint256) {
        return amount.mulDivDown(priceWad, 10 ** decimals);
    }

    function _valueUsdUp(uint256 amount, uint256 priceWad, uint8 decimals) internal pure returns (uint256) {
        return amount.mulDivUp(priceWad, 10 ** decimals);
    }

    struct AccountCtx {
        address user;
        uint256 cfg;
        uint8 eMode;
        bool open;
    }

    /// @dev Bounded by MAX_RESERVES. Uses projected indices so it is exact without prior accrual.
    function _accountData(address user) internal view returns (Types.AccountData memory a) {
        PoolStorage storage $ = _s();
        AccountCtx memory c = AccountCtx(user, $.userConfig[user], $.userEMode[user], false);
        a.healthFactor = type(uint256).max;
        if (c.cfg == 0) return a;
        c.open = _marketOpen();
        uint256 n = $.reservesList.length;
        for (uint256 i; i < n; ++i) {
            if ((c.cfg >> (i * 2)) & 3 == 0) continue;
            _accumulate(a, c, $.reservesList[i], i);
        }
        if (a.debtUsd > 0) a.healthFactor = a.weightedThresholdUsd.mulDivDown(MathLib.WAD, a.debtUsd);
    }

    function _accumulate(Types.AccountData memory a, AccountCtx memory c, address asset, uint256 id) private view {
        PoolStorage storage $ = _s();
        Types.ReserveData storage r = $.reserves[asset];
        Types.RiskParams memory p = $.assetConfig.getRiskParams(asset);
        (uint256 li, uint256 bi,) = _previewIndices(r, p.reserveFactorBps);
        uint256 price = $.oracle.getPrice(asset);
        uint8 dec = IERC20Metadata(asset).decimals();
        if (_isCollateral(c.cfg, id)) {
            uint256 v = _valueUsd(IReceiptToken(r.receiptToken).balanceOf(c.user).rayMulDown(li), price, dec);
            if (v > 0) {
                (uint256 ltv, uint256 lt,) = _effectiveParams(p, c.eMode, c.open);
                a.collateralUsd += v;
                a.borrowPowerUsd += v.bpsMulDown(ltv);
                a.weightedThresholdUsd += v.bpsMulDown(lt);
            }
        }
        if (_isBorrowing(c.cfg, id)) {
            uint256 debt = IDebtToken(r.debtToken).scaledBalanceOf(c.user).rayMulUp(bi);
            a.debtUsd += _valueUsdUp(debt, price, dec);
        }
    }

    /// @dev Every action that reduces account safety must leave debt within LTV-based borrow power.
    function _requireSolvent(address user) internal view {
        if (_s().userConfig[user] & BORROWING_MASK == 0) return; // no debt, nothing to check
        Types.AccountData memory a = _accountData(user);
        if (a.debtUsd > a.borrowPowerUsd) revert LLErrors.InsufficientCollateral();
    }

    function _checkCompliance(address account, uint8 action) internal view {
        IComplianceRegistry c = _s().compliance;
        if (address(c) != address(0) && !c.isAllowed(account, action)) revert LLErrors.NotCompliant();
    }

    // ------------------------------------------------------------------
    // Staker borrow-rate discount
    // ------------------------------------------------------------------

    /// @dev Rebates part of the protocol's share of interest accrued on `user`'s debt since their last
    ///      touch. Funded entirely from the treasury accrual so suppliers are never affected. A failing
    ///      hook can never block repayments or liquidations.
    function _applyDiscount(address asset, Types.ReserveData storage r, address user, uint256 rfBps) internal {
        IDebtToken dt = IDebtToken(r.debtToken);
        uint256 bi = r.borrowIndex;
        uint256 scaled = dt.scaledBalanceOf(user);
        uint256 last = dt.userIndex(user);
        IProjectTokenHooks h = _s().hooks;
        if (scaled == 0 || last == 0 || bi <= last || address(h) == address(0) || rfBps == 0) {
            dt.setUserIndex(user, bi);
            return;
        }
        uint256 discountBps = 0;
        try h.borrowDiscountBps(user) returns (uint256 d) {
            discountBps = d > MathLib.BPS ? MathLib.BPS : d;
        } catch {}
        if (discountBps > 0) {
            uint256 interest = scaled.mulDivDown(bi - last, MathLib.RAY);
            uint256 rebate = interest.mulDivDown(rfBps * discountBps, MathLib.BPS * MathLib.BPS);
            uint256 treasuryAssets = uint256(r.accruedToTreasuryScaled).rayMulDown(r.liquidityIndex);
            if (rebate > treasuryAssets) rebate = treasuryAssets;
            uint256 debtScaled = rebate.rayDivDown(bi);
            if (debtScaled > scaled) debtScaled = scaled;
            rebate = debtScaled.rayMulDown(bi);
            uint256 treasuryScaled = rebate.rayDivUp(r.liquidityIndex);
            if (debtScaled > 0 && treasuryScaled <= r.accruedToTreasuryScaled) {
                r.accruedToTreasuryScaled -= uint128(treasuryScaled);
                dt.burnScaled(user, debtScaled, bi);
                emit IPool.BorrowDiscountApplied(asset, user, rebate);
            }
        }
        dt.setUserIndex(user, bi);
    }
}
