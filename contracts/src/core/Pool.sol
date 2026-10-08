// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

import {PoolBase} from "./PoolBase.sol";
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
import {IReceiptToken, IDebtToken} from "../interfaces/ITokens.sol";

/// @title Ledgerline Pool
/// @notice Pooled money market for stablecoins and tokenized equities. Holds all liquidity, tracks
///         supply/debt via RAY indices and enforces health. Liquidations and flash loans run in
///         immutable delegatecall modules that share this contract's namespaced storage.
contract Pool is IPool, PoolBase, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");

    address public immutable LIQUIDATION_LOGIC;
    address public immutable FLASH_LOAN;

    constructor(address admin, address guardian, IAssetConfig assetConfig_, address liquidationLogic, address flashLoanModule) {
        if (
            admin == address(0) || guardian == address(0) || address(assetConfig_) == address(0)
                || liquidationLogic == address(0) || flashLoanModule == address(0)
        ) revert LLErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(CONFIGURATOR_ROLE, address(assetConfig_));
        _s().assetConfig = assetConfig_;
        _s().flashFeeBps = 5; // 0.05%
        LIQUIDATION_LOGIC = liquidationLogic;
        FLASH_LOAN = flashLoanModule;
    }

    // ==================================================================
    // User actions
    // ==================================================================

    /// @inheritdoc IPool
    function supply(address asset, uint256 amount, address onBehalfOf)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (amount == 0) revert LLErrors.ZeroAmount();
        if (onBehalfOf == address(0)) revert LLErrors.ZeroAddress();
        Types.ReserveData storage r = _reserve(asset);
        if (r.frozen) revert LLErrors.ReserveFrozen();
        if (r.paused) revert LLErrors.ReservePaused();
        _checkCompliance(onBehalfOf, Types.ACTION_SUPPLY);
        Types.RiskParams memory p = _s().assetConfig.getRiskParams(asset);
        _accrue(asset, r);
        if (p.supplyCap != 0 && _totalSupplyOf(r) + amount > p.supplyCap) revert LLErrors.SupplyCapExceeded();

        shares = amount.rayDivDown(r.liquidityIndex);
        if (shares == 0) revert LLErrors.ZeroAmount();
        bool first = IReceiptToken(r.receiptToken).balanceOf(onBehalfOf) == 0;

        r.cash += uint128(amount);
        _updateRate(asset, r);
        if (first && p.collateralEnabled) {
            _setCollateral(onBehalfOf, r.id, true);
            emit CollateralToggled(asset, onBehalfOf, true);
        }
        emit Supply(asset, msg.sender, onBehalfOf, amount, shares);

        IReceiptToken(r.receiptToken).mintShares(onBehalfOf, shares);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IPool
    function withdraw(address asset, uint256 amount, address to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        (uint256 assets,) = _withdraw(asset, msg.sender, to, amount, false);
        return assets;
    }

    /// @inheritdoc IPool
    function vaultWithdraw(address asset, address owner, address receiver, uint256 amount, bool sharesMode)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets, uint256 shares)
    {
        if (msg.sender != _s().reserves[asset].receiptToken) revert LLErrors.OnlyReceiptToken();
        return _withdraw(asset, owner, receiver, amount, sharesMode);
    }

    // Calls here go only to protocol-owned contracts without callbacks (receipt/debt tokens, IRM, AssetConfig, oracle) under nonReentrant; see docs/SLITHER.md.
    // slither-disable-start reentrancy-no-eth
    function _withdraw(address asset, address owner, address to, uint256 amount, bool sharesMode)
        internal
        returns (uint256 assets, uint256 shares)
    {
        if (amount == 0) revert LLErrors.ZeroAmount();
        if (to == address(0)) revert LLErrors.ZeroAddress();
        Types.ReserveData storage r = _reserve(asset);
        if (r.paused) revert LLErrors.ReservePaused();
        _accrue(asset, r);

        uint256 balance = IReceiptToken(r.receiptToken).balanceOf(owner);
        if (sharesMode) {
            shares = amount;
            assets = shares.rayMulDown(r.liquidityIndex);
        } else if (amount == type(uint256).max) {
            shares = balance;
            assets = shares.rayMulDown(r.liquidityIndex);
        } else {
            assets = amount;
            shares = assets.rayDivUp(r.liquidityIndex); // burn rounds against the user
        }
        if (shares > balance || shares == 0) revert LLErrors.InsufficientBalance();
        if (assets > r.cash) revert LLErrors.InsufficientLiquidity();

        r.cash -= uint128(assets);
        IReceiptToken(r.receiptToken).burnShares(owner, shares);
        _updateRate(asset, r);
        if (shares == balance && _isCollateral(_s().userConfig[owner], r.id)) {
            _setCollateral(owner, r.id, false);
            emit CollateralToggled(asset, owner, false);
        }
        _requireSolvent(owner);
        emit Withdraw(asset, owner, to, assets, shares);

        IERC20(asset).safeTransfer(to, assets);
    }
    // slither-disable-end reentrancy-no-eth

    // Calls here go only to protocol-owned contracts without callbacks (receipt/debt tokens, IRM, AssetConfig, oracle) under nonReentrant; see docs/SLITHER.md.
    // slither-disable-start reentrancy-no-eth
    /// @inheritdoc IPool
    function borrow(address asset, uint256 amount) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert LLErrors.ZeroAmount();
        Types.ReserveData storage r = _reserve(asset);
        if (r.frozen) revert LLErrors.ReserveFrozen();
        if (r.paused) revert LLErrors.ReservePaused();
        _checkCompliance(msg.sender, Types.ACTION_BORROW);
        Types.RiskParams memory p = _s().assetConfig.getRiskParams(asset);
        if (!p.borrowEnabled) revert LLErrors.BorrowingDisabled();
        uint8 em = _s().userEMode[msg.sender];
        if (em != 0 && p.eModeCategory != em) revert LLErrors.EModeMismatch();

        _accrue(asset, r);
        uint256 debtAfter = _totalDebtOf(r) + amount;
        if (p.borrowCap != 0 && debtAfter > p.borrowCap) revert LLErrors.BorrowCapExceeded();
        if (p.isStock && !_marketOpen() && debtAfter > p.closedBorrowCap) revert LLErrors.ClosedMarketBorrowCapExceeded();
        if (amount > r.cash) revert LLErrors.InsufficientLiquidity();

        _applyDiscount(asset, r, msg.sender, p.reserveFactorBps);
        shares = amount.rayDivUp(r.borrowIndex); // debt rounds against the borrower
        IDebtToken(r.debtToken).mintScaled(msg.sender, shares, r.borrowIndex);
        _setBorrowing(msg.sender, r.id, true);
        r.cash -= uint128(amount);
        _updateRate(asset, r);
        _requireSolvent(msg.sender);
        emit Borrow(asset, msg.sender, amount, shares, r.borrowRateRay);

        IERC20(asset).safeTransfer(msg.sender, amount);
    }
    // slither-disable-end reentrancy-no-eth

    // Calls here go only to protocol-owned contracts without callbacks (receipt/debt tokens, IRM, AssetConfig, oracle) under nonReentrant; see docs/SLITHER.md.
    // slither-disable-start reentrancy-no-eth
    /// @inheritdoc IPool
    /// @dev Never gated by pause flags or compliance: users must always be able to de-risk.
    function repay(address asset, uint256 amount, address onBehalfOf) external nonReentrant returns (uint256 repaid) {
        if (amount == 0) revert LLErrors.ZeroAmount();
        Types.ReserveData storage r = _reserve(asset);
        _accrue(asset, r);
        _applyDiscount(asset, r, onBehalfOf, _s().assetConfig.getRiskParams(asset).reserveFactorBps);

        uint256 scaled = IDebtToken(r.debtToken).scaledBalanceOf(onBehalfOf);
        if (scaled == 0) revert LLErrors.NoDebt();
        uint256 debt = scaled.rayMulUp(r.borrowIndex);
        uint256 shares;
        if (amount >= debt) {
            repaid = debt;
            shares = scaled;
        } else {
            repaid = amount;
            shares = amount.rayDivDown(r.borrowIndex);
        }
        IDebtToken(r.debtToken).burnScaled(onBehalfOf, shares, r.borrowIndex);
        if (shares == scaled) _setBorrowing(onBehalfOf, r.id, false);
        r.cash += uint128(repaid);
        _updateRate(asset, r);
        emit Repay(asset, msg.sender, onBehalfOf, repaid, shares);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), repaid);
    }
    // slither-disable-end reentrancy-no-eth

    /// @inheritdoc IPool
    function setUseAsCollateral(address asset, bool enabled) external nonReentrant whenNotPaused {
        Types.ReserveData storage r = _reserve(asset);
        if (enabled) {
            if (!_s().assetConfig.getRiskParams(asset).collateralEnabled) revert LLErrors.CollateralDisabled();
            if (IReceiptToken(r.receiptToken).balanceOf(msg.sender) == 0) revert LLErrors.InsufficientBalance();
        }
        _setCollateral(msg.sender, r.id, enabled);
        if (!enabled) _requireSolvent(msg.sender);
        emit CollateralToggled(asset, msg.sender, enabled);
    }

    /// @inheritdoc IPool
    function setEMode(uint8 category) external nonReentrant whenNotPaused {
        PoolStorage storage $ = _s();
        if (category != 0) {
            if ($.assetConfig.getEModeCategory(category).liqThresholdBps == 0) revert LLErrors.InvalidParams();
            uint256 cfg = $.userConfig[msg.sender];
            uint256 n = $.reservesList.length;
            for (uint256 i; i < n; ++i) {
                if (_isBorrowing(cfg, i) && $.assetConfig.getRiskParams($.reservesList[i]).eModeCategory != category) {
                    revert LLErrors.EModeMismatch();
                }
            }
        }
        $.userEMode[msg.sender] = category;
        _requireSolvent(msg.sender);
        emit EModeSet(msg.sender, category);
    }

    /// @inheritdoc IPool
    function liquidate(address collateralAsset, address debtAsset, address user, uint256 debtToCover, bool receiveReceipt)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 debtRepaid, uint256 collateralSeized)
    {
        bytes memory ret = Address.functionDelegateCall(
            LIQUIDATION_LOGIC,
            abi.encodeWithSignature(
                "liquidate(address,address,address,uint256,bool,address)",
                collateralAsset,
                debtAsset,
                user,
                debtToCover,
                receiveReceipt,
                msg.sender
            )
        );
        (debtRepaid, collateralSeized) = abi.decode(ret, (uint256, uint256));
    }

    // The FlashLoan module returns nothing; failures bubble up as reverts.
    // slither-disable-start unused-return
    /// @notice ERC-3156 flash loan. The receiver cannot re-enter the Pool during the callback.
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        Address.functionDelegateCall(
            FLASH_LOAN,
            abi.encodeWithSignature(
                "flashLoan(address,address,uint256,bytes,address)", address(receiver), token, amount, data, msg.sender
            )
        );
        return true;
    }
    // slither-disable-end unused-return

    function maxFlashLoan(address token) external view returns (uint256) {
        Types.ReserveData storage r = _s().reserves[token];
        return r.active && !r.paused ? r.cash : 0;
    }

    function flashFee(address token, uint256 amount) external view returns (uint256) {
        if (!_s().reserves[token].active) revert LLErrors.ReserveNotActive();
        return amount.bpsMulUp(_s().flashFeeBps);
    }

    /// @inheritdoc IPool
    function accrue(address asset) external nonReentrant {
        Types.ReserveData storage r = _reserve(asset);
        _accrue(asset, r);
        _updateRate(asset, r);
    }

    /// @notice Mints accrued protocol shares to the FeeCollector. Permissionless.
    function mintToTreasury(address asset) external nonReentrant {
        Types.ReserveData storage r = _reserve(asset);
        address fc = _s().feeCollector;
        if (fc == address(0)) revert LLErrors.ZeroAddress();
        _accrue(asset, r);
        uint256 shares = r.accruedToTreasuryScaled;
        if (shares == 0) return;
        r.accruedToTreasuryScaled = 0;
        emit MintedToTreasury(asset, shares);
        IReceiptToken(r.receiptToken).mintShares(fc, shares);
    }

    // ==================================================================
    // Receipt-token hook
    // ==================================================================

    /// @inheritdoc IPool
    function finalizeTransfer(address asset, address from, address to, uint256 shares) external nonReentrant whenNotPaused {
        Types.ReserveData storage r = _s().reserves[asset];
        if (msg.sender != r.receiptToken || r.receiptToken == address(0)) revert LLErrors.OnlyReceiptToken();
        if (r.paused) revert LLErrors.ReservePaused();
        if (shares == 0 || from == to) return;
        _checkCompliance(to, Types.ACTION_RECEIVE_TRANSFER);
        IReceiptToken rt = IReceiptToken(r.receiptToken);
        if (_isCollateral(_s().userConfig[from], r.id)) {
            if (rt.balanceOf(from) == 0) {
                _setCollateral(from, r.id, false);
                emit CollateralToggled(asset, from, false);
            }
            _requireSolvent(from);
        }
        if (rt.balanceOf(to) == shares && _s().assetConfig.getRiskParams(asset).collateralEnabled) {
            _setCollateral(to, r.id, true);
            emit CollateralToggled(asset, to, true);
        }
    }

    // ==================================================================
    // Admin (DEFAULT_ADMIN_ROLE is held by the Timelock)
    // ==================================================================

    function initReserve(address asset, address receiptToken, address debtToken) external onlyRole(CONFIGURATOR_ROLE) {
        if (asset == address(0) || receiptToken == address(0) || debtToken == address(0)) revert LLErrors.ZeroAddress();
        PoolStorage storage $ = _s();
        Types.ReserveData storage r = $.reserves[asset];
        if (r.active) revert LLErrors.ReserveAlreadyListed();
        uint256 id = $.reservesList.length;
        if (id >= MAX_RESERVES) revert LLErrors.TooManyReserves();
        r.liquidityIndex = uint128(MathLib.RAY);
        r.borrowIndex = uint128(MathLib.RAY);
        r.lastUpdate = uint40(block.timestamp);
        r.id = uint8(id);
        r.active = true;
        r.receiptToken = receiptToken;
        r.debtToken = debtToken;
        $.reservesList.push(asset);
        emit ReserveInitialized(asset, receiptToken, debtToken, uint8(id));
    }

    function setOracle(IPriceOracle oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(oracle_) == address(0)) revert LLErrors.ZeroAddress();
        _s().oracle = oracle_;
        emit ModuleUpdated("oracle", address(oracle_));
    }

    /// @dev Zero disables the market-hours guard (assets treated as always open).
    function setMarketClock(IMarketClock clock_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().clock = clock_;
        emit ModuleUpdated("clock", address(clock_));
    }

    /// @dev Zero disables compliance gating.
    function setCompliance(IComplianceRegistry compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().compliance = compliance_;
        emit ModuleUpdated("compliance", address(compliance_));
    }

    function setReserve(IReserve reserve_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().reserve = reserve_;
        emit ModuleUpdated("reserve", address(reserve_));
    }

    /// @dev Zero disables staker discounts.
    function setProjectTokenHooks(IProjectTokenHooks hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().hooks = hooks_;
        emit ModuleUpdated("hooks", address(hooks_));
    }

    function setFeeCollector(address feeCollector_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeCollector_ == address(0)) revert LLErrors.ZeroAddress();
        _s().feeCollector = feeCollector_;
        emit ModuleUpdated("feeCollector", feeCollector_);
    }

    function setFlashFeeBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_FLASH_FEE_BPS) revert LLErrors.InvalidParams();
        _s().flashFeeBps = bps;
        emit FlashFeeUpdated(bps);
    }

    /// @notice Guardian can only make the system more conservative: freeze or pause.
    function setReserveFlags(address asset, bool frozen, bool paused_) external {
        Types.ReserveData storage r = _reserve(asset);
        bool loosening = (r.frozen && !frozen) || (r.paused && !paused_);
        if (loosening) _checkRole(DEFAULT_ADMIN_ROLE);
        else if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) _checkRole(GUARDIAN_ROLE);
        r.frozen = frozen;
        r.paused = paused_;
        emit ReserveFlagsUpdated(asset, frozen, paused_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Sends tokens donated directly to the Pool (above tracked cash) to the FeeCollector.
    function skim(address asset) external nonReentrant {
        Types.ReserveData storage r = _reserve(asset);
        address fc = _s().feeCollector;
        if (fc == address(0)) revert LLErrors.ZeroAddress();
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal <= r.cash) return;
        uint256 excess = bal - r.cash;
        emit Skimmed(asset, fc, excess);
        IERC20(asset).safeTransfer(fc, excess);
    }

    // ==================================================================
    // Views
    // ==================================================================

    function getReserveData(address asset) external view returns (Types.ReserveData memory) {
        return _s().reserves[asset];
    }

    function getReservesList() external view returns (address[] memory) {
        return _s().reservesList;
    }

    function getNormalizedIncome(address asset) public view returns (uint256 li) {
        Types.ReserveData storage r = _reserve(asset);
        (li,,) = _previewIndices(r, _s().assetConfig.getRiskParams(asset).reserveFactorBps);
    }

    function getNormalizedDebt(address asset) public view returns (uint256 bi) {
        Types.ReserveData storage r = _reserve(asset);
        (, bi,) = _previewIndices(r, _s().assetConfig.getRiskParams(asset).reserveFactorBps);
    }

    function totalSupplyAssets(address asset) external view returns (uint256) {
        Types.ReserveData storage r = _reserve(asset);
        (uint256 li,, uint256 ts) = _previewIndices(r, _s().assetConfig.getRiskParams(asset).reserveFactorBps);
        return (IReceiptToken(r.receiptToken).totalSupply() + ts).rayMulDown(li);
    }

    function totalDebt(address asset) external view returns (uint256) {
        Types.ReserveData storage r = _reserve(asset);
        (, uint256 bi,) = _previewIndices(r, _s().assetConfig.getRiskParams(asset).reserveFactorBps);
        return IDebtToken(r.debtToken).scaledTotalSupply().rayMulUp(bi);
    }

    function getUserAccountData(address user) external view returns (Types.AccountData memory) {
        return _accountData(user);
    }

    function getUserConfig(address user) external view returns (uint256) {
        return _s().userConfig[user];
    }

    function getUserEMode(address user) external view returns (uint8) {
        return _s().userEMode[user];
    }

    function isMarketOpen() external view returns (bool) {
        return _marketOpen();
    }

    function modules()
        external
        view
        returns (
            address assetConfig,
            address oracle,
            address clock,
            address compliance,
            address reserve,
            address hooks,
            address feeCollector,
            uint16 flashFeeBps
        )
    {
        PoolStorage storage $ = _s();
        return (
            address($.assetConfig),
            address($.oracle),
            address($.clock),
            address($.compliance),
            address($.reserve),
            address($.hooks),
            $.feeCollector,
            $.flashFeeBps
        );
    }
}
