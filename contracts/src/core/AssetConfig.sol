// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {Types} from "../libraries/Types.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IAssetConfig} from "../interfaces/IAssetConfig.sol";

interface IPoolConfigurable {
    function initReserve(address asset, address receiptToken, address debtToken) external;
    function accrue(address asset) external;
}

/// @title AssetConfig
/// @notice Risk-parameter registry and listing entry point. Holds per-asset isolated-risk settings
///         (LTV, liquidation threshold/bonus, caps, closed-market limits), interest rate models and
///         e-mode categories. RISK_ADMIN_ROLE is held by the 48h Timelock.
contract AssetConfig is IAssetConfig, AccessControl {
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");
    uint256 public constant MAX_LIQ_BONUS_BPS = 2_000;
    uint256 public constant MAX_RESERVE_FACTOR_BPS = 5_000;
    uint256 public constant MAX_LIQ_PROTOCOL_FEE_BPS = 5_000;

    IPoolConfigurable public pool;
    mapping(address => Types.RiskParams) private _params;
    mapping(address => address) public interestRateModel;
    mapping(uint8 => Types.EModeCategory) private _eModes;

    event PoolSet(address pool);
    event AssetListed(address indexed asset, address receiptToken, address debtToken, address irm);
    event RiskParamsUpdated(address indexed asset, Types.RiskParams params);
    event InterestRateModelUpdated(address indexed asset, address irm);
    event EModeCategoryUpdated(uint8 indexed id, uint16 ltvBps, uint16 liqThresholdBps, uint16 liqBonusBps, string label);

    constructor(address admin) {
        if (admin == address(0)) revert LLErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ADMIN_ROLE, admin);
    }

    /// @notice One-time wiring (the Pool's constructor needs this contract's address first).
    function setPool(address pool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pool_ == address(0)) revert LLErrors.ZeroAddress();
        if (address(pool) != address(0)) revert LLErrors.AlreadySet();
        pool = IPoolConfigurable(pool_);
        emit PoolSet(pool_);
    }

    function listAsset(
        address asset,
        address receiptToken,
        address debtToken,
        address irm,
        Types.RiskParams calldata p
    ) external onlyRole(RISK_ADMIN_ROLE) {
        if (irm == address(0)) revert LLErrors.ZeroAddress();
        _validate(p);
        _params[asset] = p;
        interestRateModel[asset] = irm;
        emit AssetListed(asset, receiptToken, debtToken, irm);
        emit RiskParamsUpdated(asset, p);
        pool.initReserve(asset, receiptToken, debtToken);
    }

    /// @dev Accrues first so a reserve-factor change never applies retroactively.
    function setRiskParams(address asset, Types.RiskParams calldata p) external onlyRole(RISK_ADMIN_ROLE) {
        if (interestRateModel[asset] == address(0)) revert LLErrors.ReserveNotActive();
        _validate(p);
        pool.accrue(asset);
        _params[asset] = p;
        emit RiskParamsUpdated(asset, p);
    }

// pool is the immutable, trusted Pool; accrue before and after the switch is intentional.
    // slither-disable-start reentrancy-no-eth
    function setInterestRateModel(address asset, address irm) external onlyRole(RISK_ADMIN_ROLE) {
        if (irm == address(0)) revert LLErrors.ZeroAddress();
        if (interestRateModel[asset] == address(0)) revert LLErrors.ReserveNotActive();
        pool.accrue(asset);
        interestRateModel[asset] = irm;
        emit InterestRateModelUpdated(asset, irm);
        pool.accrue(asset); // refresh the stored rate with the new model
    }
    // slither-disable-end reentrancy-no-eth

    function setEModeCategory(uint8 id, uint16 ltvBps, uint16 liqThresholdBps, uint16 liqBonusBps, string calldata label)
        external
        onlyRole(RISK_ADMIN_ROLE)
    {
        if (id == 0) revert LLErrors.InvalidParams();
        _validateTriple(ltvBps, liqThresholdBps, liqBonusBps);
        _eModes[id] = Types.EModeCategory(ltvBps, liqThresholdBps, liqBonusBps, label);
        emit EModeCategoryUpdated(id, ltvBps, liqThresholdBps, liqBonusBps, label);
    }

    function getRiskParams(address asset) external view returns (Types.RiskParams memory) {
        return _params[asset];
    }

    function getEModeCategory(uint8 id) external view returns (Types.EModeCategory memory) {
        return _eModes[id];
    }

    function _validate(Types.RiskParams calldata p) private view {
        _validateTriple(p.ltvBps, p.liqThresholdBps, p.liqBonusBps);
        if (p.closedLtvBps > p.ltvBps) revert LLErrors.InvalidParams();
        if (p.reserveFactorBps > MAX_RESERVE_FACTOR_BPS) revert LLErrors.InvalidParams();
        if (p.liqProtocolFeeBps > MAX_LIQ_PROTOCOL_FEE_BPS) revert LLErrors.InvalidParams();
        if (p.eModeCategory != 0 && _eModes[p.eModeCategory].liqThresholdBps == 0) revert LLErrors.InvalidParams();
        if (p.closedBorrowCap != 0 && p.borrowCap != 0 && p.closedBorrowCap > p.borrowCap) revert LLErrors.InvalidParams();
    }

    /// @dev ltv <= lt and lt * (1 + bonus) < 100%, so a liquidation always improves health.
    function _validateTriple(uint256 ltv, uint256 lt, uint256 bonus) private pure {
        if (ltv > lt || lt >= MathLib.BPS || bonus > MAX_LIQ_BONUS_BPS) revert LLErrors.InvalidParams();
        if (lt * (MathLib.BPS + bonus) >= MathLib.BPS * MathLib.BPS) revert LLErrors.InvalidParams();
    }
}
