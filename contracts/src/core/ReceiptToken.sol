// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {MathLib} from "../libraries/MathLib.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {Types} from "../libraries/Types.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IAssetConfig} from "../interfaces/IAssetConfig.sol";

/// @title ReceiptToken
/// @notice Interest-bearing, non-rebasing supply share with the ERC-4626 interface. One share is
///         worth `liquidityIndex` underlying. Liquidity lives in the Pool, and the exchange rate is
///         driven by the Pool's internal index, so direct donations cannot move it (no first-depositor
///         inflation attack).
contract ReceiptToken is ERC20, IERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    IPool public immutable POOL;
    IAssetConfig public immutable ASSET_CONFIG;
    address public immutable UNDERLYING;
    uint8 private immutable _DECIMALS;

    modifier onlyPool() {
        if (msg.sender != address(POOL)) revert LLErrors.OnlyPool();
        _;
    }

    constructor(IPool pool_, IAssetConfig assetConfig_, address underlying_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        if (address(pool_) == address(0) || underlying_ == address(0) || address(assetConfig_) == address(0)) {
            revert LLErrors.ZeroAddress();
        }
        POOL = pool_;
        ASSET_CONFIG = assetConfig_;
        UNDERLYING = underlying_;
        _DECIMALS = IERC20Metadata(underlying_).decimals();
    }

    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _DECIMALS;
    }

    // ---------------- pool-only ----------------

    function mintShares(address to, uint256 shares) external onlyPool {
        _mint(to, shares);
    }

    function burnShares(address from, uint256 shares) external onlyPool {
        _burn(from, shares);
    }

    /// @dev Used during liquidations; bypasses the health hook (the Pool already validated).
    function poolTransfer(address from, address to, uint256 shares) external onlyPool {
        _transfer(from, to, shares);
    }

    // ---------------- transfers with health check ----------------

    function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        super.transfer(to, value);
        POOL.finalizeTransfer(UNDERLYING, msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        super.transferFrom(from, to, value);
        POOL.finalizeTransfer(UNDERLYING, from, to, value);
        return true;
    }

    // ---------------- ERC-4626 views ----------------

    function asset() external view returns (address) {
        return UNDERLYING;
    }

    function totalAssets() external view returns (uint256) {
        return totalSupply().rayMulDown(POOL.getNormalizedIncome(UNDERLYING));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.rayDivDown(POOL.getNormalizedIncome(UNDERLYING));
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.rayMulDown(POOL.getNormalizedIncome(UNDERLYING));
    }

    /// @notice Current underlying value of `account`'s shares.
    function balanceOfAssets(address account) external view returns (uint256) {
        return convertToAssets(balanceOf(account));
    }

    function maxDeposit(address) public view returns (uint256) {
        Types.ReserveData memory r = POOL.getReserveData(UNDERLYING);
        if (!r.active || r.frozen || r.paused) return 0;
        uint256 cap = ASSET_CONFIG.getRiskParams(UNDERLYING).supplyCap;
        if (cap == 0) return type(uint256).max;
        uint256 supplied = POOL.totalSupplyAssets(UNDERLYING);
        return supplied >= cap ? 0 : cap - supplied;
    }

    function maxMint(address receiver) external view returns (uint256) {
        uint256 a = maxDeposit(receiver);
        return a == type(uint256).max ? a : convertToShares(a);
    }

    /// @dev Upper bound from balance and pool cash; health-factor limits are enforced at execution.
    function maxWithdraw(address owner) public view returns (uint256) {
        Types.ReserveData memory r = POOL.getReserveData(UNDERLYING);
        if (r.paused) return 0;
        return MathLib.min(convertToAssets(balanceOf(owner)), r.cash);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return MathLib.min(balanceOf(owner), convertToShares(maxWithdraw(owner)));
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return shares.rayMulUp(POOL.getNormalizedIncome(UNDERLYING));
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return assets.rayDivUp(POOL.getNormalizedIncome(UNDERLYING));
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    // ---------------- ERC-4626 mutators (routed through the Pool) ----------------

    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        IERC20(UNDERLYING).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(UNDERLYING).forceApprove(address(POOL), assets);
        shares = POOL.supply(UNDERLYING, assets, receiver);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = previewMint(shares);
        deposit(assets, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, previewWithdraw(assets));
        uint256 withdrawn;
        (withdrawn, shares) = POOL.vaultWithdraw(UNDERLYING, owner, receiver, assets, false);
        emit Withdraw(msg.sender, receiver, owner, withdrawn, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        uint256 burned;
        (assets, burned) = POOL.vaultWithdraw(UNDERLYING, owner, receiver, shares, true);
        emit Withdraw(msg.sender, receiver, owner, assets, burned);
    }
}
