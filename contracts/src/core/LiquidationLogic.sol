// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolBase} from "./PoolBase.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {Types} from "../libraries/Types.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IReserve} from "../interfaces/IReserve.sol";
import {IReceiptToken, IDebtToken} from "../interfaces/ITokens.sol";

/// @title LiquidationLogic
/// @notice Delegatecall module of the Pool. Permissionless partial liquidations with a close factor,
///         plus bad-debt write-off (Reserve first, then socialized across suppliers).
/// @dev Only reachable through `Pool.liquidate`, which holds the reentrancy lock and pause check.
contract LiquidationLogic is PoolBase {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    address private immutable SELF = address(this);

    struct Vars {
        Types.RiskParams cp;
        uint256 debtPrice;
        uint256 collPrice;
        uint256 userDebtScaled;
        uint256 userDebt;
        uint256 userCollShares;
        uint256 userColl;
        uint256 bonus;
        uint256 repay;
        uint256 seize;
        uint256 protocolFee;
        uint256 seizedShares;
        uint256 feeShares;
        uint256 liquidatorShares;
        uint256 liquidatorAssets;
        uint8 debtDec;
        uint8 collDec;
    }

    struct Cover {
        address asset;
        uint256 amount;
    }

    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert LLErrors.OnlyDelegateCall();
        _;
    }

    struct Params {
        address collateralAsset;
        address debtAsset;
        address user;
        address liquidator;
        uint256 debtToCover;
        bool receiveReceipt;
    }

    function liquidate(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveReceipt,
        address liquidator
    ) external onlyDelegateCall returns (uint256, uint256) {
        if (debtToCover == 0) revert LLErrors.ZeroAmount();
        return _liquidate(Params(collateralAsset, debtAsset, user, liquidator, debtToCover, receiveReceipt));
    }

    // Calls here go only to protocol-owned contracts without callbacks (receipt/debt tokens, IRM, AssetConfig, oracle) under nonReentrant; see docs/SLITHER.md.
    // slither-disable-start reentrancy-no-eth,arbitrary-send-erc20,reentrancy-balance
    function _liquidate(Params memory q) private returns (uint256, uint256) {
        Types.ReserveData storage cr = _reserve(q.collateralAsset);
        Types.ReserveData storage dr = _reserve(q.debtAsset);
        if (cr.paused || dr.paused) revert LLErrors.ReservePaused();
        _accrue(q.collateralAsset, cr);
        _accrue(q.debtAsset, dr);

        uint256 hf = _accountData(q.user).healthFactor;
        if (hf >= HF_ONE) revert LLErrors.HealthyAccount();
        if (!_isCollateral(_s().userConfig[q.user], cr.id)) revert LLErrors.NoCollateral();
        _applyDiscount(q.debtAsset, dr, q.user, _s().assetConfig.getRiskParams(q.debtAsset).reserveFactorBps);

        Vars memory v = _compute(q.collateralAsset, q.debtAsset, cr, dr, q.user, q.debtToCover, hf);

        // ---- effects: debt side ----
        uint256 burnDebt = v.repay == v.userDebt ? v.userDebtScaled : v.repay.rayDivDown(dr.borrowIndex);
        IDebtToken(dr.debtToken).burnScaled(q.user, burnDebt, dr.borrowIndex);
        if (burnDebt == v.userDebtScaled) _setBorrowing(q.user, dr.id, false);
        dr.cash += uint128(v.repay);
        _updateRate(q.debtAsset, dr);

        // ---- effects: collateral side ----
        _seize(q.collateralAsset, cr, q.user, q.liquidator, q.receiveReceipt, v);

        // ---- bad debt: no collateral left but debt remains ----
        (Cover[] memory covers, uint256 nCovers) = _maybeWriteOff(q.user);

        _emitLiquidation(q, v);

        // ---- interactions ----
        // q.liquidator is always the Pool's msg.sender (set by Pool.liquidate), never user input.
        IERC20(q.debtAsset).safeTransferFrom(q.liquidator, address(this), v.repay);
        if (!q.receiveReceipt) IERC20(q.collateralAsset).safeTransfer(q.liquidator, v.liquidatorAssets);
        IReserve res = _s().reserve;
        for (uint256 i; i < nCovers; ++i) {
            // amounts were capped to the Reserve's balance above, so anything less is a fault
            if (res.coverBadDebt(covers[i].asset, covers[i].amount) != covers[i].amount) revert LLErrors.InvalidParams();
        }
        return (v.repay, v.seize);
    }
    // slither-disable-end reentrancy-no-eth,arbitrary-send-erc20,reentrancy-balance

    function _emitLiquidation(Params memory q, Vars memory v) private {
        emit IPool.Liquidation(
            q.collateralAsset, q.debtAsset, q.user, q.liquidator, v.repay, v.seize, v.protocolFee, q.receiveReceipt
        );
    }

    function _compute(
        address collateralAsset,
        address debtAsset,
        Types.ReserveData storage cr,
        Types.ReserveData storage dr,
        address user,
        uint256 debtToCover,
        uint256 hf
    ) private view returns (Vars memory v) {
        PoolStorage storage $ = _s();
        v.cp = $.assetConfig.getRiskParams(collateralAsset);
        v.userDebtScaled = IDebtToken(dr.debtToken).scaledBalanceOf(user);
        v.userDebt = v.userDebtScaled.rayMulUp(dr.borrowIndex);
        if (v.userDebt == 0) revert LLErrors.NoDebt();
        v.userCollShares = IReceiptToken(cr.receiptToken).balanceOf(user);
        v.userColl = v.userCollShares.rayMulDown(cr.liquidityIndex);
        if (v.userColl == 0) revert LLErrors.NoCollateral();

        uint256 maxRepay = hf < FULL_CLOSE_HF ? v.userDebt : v.userDebt.bpsMulUp(CLOSE_FACTOR_BPS);
        v.repay = debtToCover < maxRepay ? debtToCover : maxRepay;
        (,, v.bonus) = _effectiveParams(v.cp, $.userEMode[user], _marketOpen());
        v.debtPrice = $.oracle.getPrice(debtAsset);
        v.collPrice = $.oracle.getPrice(collateralAsset);
        v.debtDec = IERC20Metadata(debtAsset).decimals();
        v.collDec = IERC20Metadata(collateralAsset).decimals();

        // collateral = repay * debtPrice / collPrice * (1 + bonus), decimal-adjusted
        uint256 num = v.debtPrice * (10 ** v.collDec) * (MathLib.BPS + v.bonus);
        uint256 den = v.collPrice * (10 ** v.debtDec) * MathLib.BPS;
        v.seize = v.repay.mulDivDown(num, den);
        if (v.seize > v.userColl) {
            v.seize = v.userColl;
            v.repay = v.seize.mulDivUp(den, num);
            if (v.repay > v.userDebt) v.repay = v.userDebt;
        }
        if (v.repay == 0 || v.seize == 0) revert LLErrors.ZeroAmount();
        uint256 bonusPart = v.seize - v.seize.mulDivDown(MathLib.BPS, MathLib.BPS + v.bonus);
        v.protocolFee = $.feeCollector == address(0) ? 0 : bonusPart.bpsMulDown(v.cp.liqProtocolFeeBps);
    }

    // Calls here go only to protocol-owned contracts without callbacks (receipt/debt tokens, IRM, AssetConfig, oracle) under nonReentrant; see docs/SLITHER.md.
    // slither-disable-start reentrancy-no-eth
    function _seize(
        address asset,
        Types.ReserveData storage cr,
        address user,
        address liquidator,
        bool receiveReceipt,
        Vars memory v
    ) private {
        IReceiptToken rt = IReceiptToken(cr.receiptToken);
        uint256 li = cr.liquidityIndex;
        v.seizedShares = v.seize == v.userColl ? v.userCollShares : v.seize.rayDivUp(li);
        if (v.seizedShares > v.userCollShares) v.seizedShares = v.userCollShares;
        v.feeShares = v.protocolFee.rayDivDown(li);
        v.liquidatorShares = v.seizedShares - v.feeShares;

        if (v.feeShares > 0) rt.poolTransfer(user, _s().feeCollector, v.feeShares);
        if (receiveReceipt) {
            bool first = rt.balanceOf(liquidator) == 0;
            rt.poolTransfer(user, liquidator, v.liquidatorShares);
            if (first && v.cp.collateralEnabled) {
                _setCollateral(liquidator, cr.id, true);
                emit IPool.CollateralToggled(asset, liquidator, true);
            }
        } else {
            v.liquidatorAssets = v.liquidatorShares.rayMulDown(li);
            if (v.liquidatorAssets > cr.cash) revert LLErrors.InsufficientLiquidity();
            rt.burnShares(user, v.liquidatorShares);
            cr.cash -= uint128(v.liquidatorAssets);
            _updateRate(asset, cr);
        }
        if (rt.balanceOf(user) == 0) {
            _setCollateral(user, cr.id, false);
            emit IPool.CollateralToggled(asset, user, false);
        }
    }
    // slither-disable-end reentrancy-no-eth

    /// @dev If the account has no collateral left, every remaining debt is written off. Bounded by MAX_RESERVES.
    function _maybeWriteOff(address user) private returns (Cover[] memory covers, uint256 n) {
        PoolStorage storage $ = _s();
        uint256 cfg = $.userConfig[user];
        uint256 count = $.reservesList.length;
        for (uint256 i; i < count; ++i) {
            if (_isCollateral(cfg, i)) {
                if (IReceiptToken($.reserves[$.reservesList[i]].receiptToken).balanceOf(user) > 0) return (covers, 0);
            }
        }
        covers = new Cover[](count);
        for (uint256 i; i < count; ++i) {
            if (!_isBorrowing(cfg, i)) continue;
            address asset = $.reservesList[i];
            uint256 covered = _writeOff(asset, user);
            if (covered > 0) covers[n++] = Cover(asset, covered);
        }
    }

    // Calls here go only to protocol-owned contracts without callbacks (receipt/debt tokens, IRM, AssetConfig, oracle) under nonReentrant; see docs/SLITHER.md.
    // slither-disable-start reentrancy-no-eth
    function _writeOff(address asset, address user) private returns (uint256 covered) {
        PoolStorage storage $ = _s();
        Types.ReserveData storage r = $.reserves[asset];
        _accrue(asset, r);
        IDebtToken dt = IDebtToken(r.debtToken);
        uint256 scaled = dt.scaledBalanceOf(user);
        uint256 amount = scaled.rayMulUp(r.borrowIndex);
        dt.burnScaled(user, scaled, r.borrowIndex);
        _setBorrowing(user, r.id, false);

        if (address($.reserve) != address(0)) {
            covered = MathLib.min(IERC20(asset).balanceOf(address($.reserve)), amount);
        }
        uint256 socialized = amount - covered;
        r.cash += uint128(covered);
        if (socialized > 0) {
            uint256 totalShares = IReceiptToken(r.receiptToken).totalSupply() + r.accruedToTreasuryScaled;
            uint256 li = r.liquidityIndex;
            if (totalShares > 0) {
                uint256 delta = socialized.mulDivUp(MathLib.RAY, totalShares);
                r.liquidityIndex = uint128(li > delta ? li - delta : 1);
            }
        }
        _updateRate(asset, r);
        emit IPool.BadDebtWrittenOff(asset, user, amount, covered, socialized);
    }
    // slither-disable-end reentrancy-no-eth
}
