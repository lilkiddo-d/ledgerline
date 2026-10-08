// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {MathLib} from "../libraries/MathLib.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {Types} from "../libraries/Types.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IProjectTokenHooks} from "../interfaces/IProjectTokenHooks.sol";

interface IPoolTreasury {
    function mintToTreasury(address asset) external;
}

/// @title FeeCollector
/// @notice Receives protocol revenue (reserve-factor interest, liquidation fees, flash-loan fees) as
///         receipt tokens, redeems it, optionally swaps it to the stablecoin with oracle-checked
///         slippage and a deadline, and distributes: Reserve (bad-debt backstop), stakers (via
///         ProjectTokenHooks, only once the project token is live) and the treasury.
contract FeeCollector is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    IPool public immutable POOL;
    address public immutable STABLECOIN;

    address public reserve;
    address public treasury;
    IProjectTokenHooks public hooks;
    ISwapAdapter public swapAdapter;
    IPriceOracle public oracle;
    uint16 public reserveShareBps = 2_000;
    uint16 public stakerShareBps = 3_000;
    uint16 public maxSlippageBps = 100;

    event Redeemed(address indexed asset, uint256 shares, uint256 assets);
    event Swapped(address indexed tokenIn, uint256 amountIn, uint256 amountOut);
    event Distributed(address indexed token, uint256 toReserve, uint256 toStakers, uint256 toTreasury);
    event ConfigUpdated(address reserve, address treasury, address hooks, address swapAdapter, address oracle);
    event SharesUpdated(uint16 reserveShareBps, uint16 stakerShareBps, uint16 maxSlippageBps);

    constructor(address admin, IPool pool, address stablecoin, address reserve_, address treasury_, IPriceOracle oracle_) {
        if (
            admin == address(0) || address(pool) == address(0) || stablecoin == address(0) || reserve_ == address(0)
                || treasury_ == address(0)
        ) revert LLErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
        POOL = pool;
        STABLECOIN = stablecoin;
        reserve = reserve_;
        treasury = treasury_;
        oracle = oracle_;
    }

    // ---------------- admin ----------------

    function setConfig(address reserve_, address treasury_, IProjectTokenHooks hooks_, ISwapAdapter swap_, IPriceOracle oracle_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (reserve_ == address(0) || treasury_ == address(0)) revert LLErrors.ZeroAddress();
        reserve = reserve_;
        treasury = treasury_;
        hooks = hooks_;
        swapAdapter = swap_;
        oracle = oracle_;
        emit ConfigUpdated(reserve_, treasury_, address(hooks_), address(swap_), address(oracle_));
    }

    function setShares(uint16 reserveBps, uint16 stakerBps, uint16 slippageBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (uint256(reserveBps) + stakerBps > MathLib.BPS || slippageBps > MAX_SLIPPAGE_BPS) revert LLErrors.InvalidParams();
        reserveShareBps = reserveBps;
        stakerShareBps = stakerBps;
        maxSlippageBps = slippageBps;
        emit SharesUpdated(reserveBps, stakerBps, slippageBps);
    }

    // ---------------- keeper flow ----------------

    /// @notice Mints accrued protocol shares and redeems as much as pool liquidity allows. Permissionless.
    function harvest(address asset) external nonReentrant returns (uint256 assets) {
        IPoolTreasury(address(POOL)).mintToTreasury(asset);
        Types.ReserveData memory r = POOL.getReserveData(asset);
        IERC20 rt = IERC20(r.receiptToken);
        uint256 shares = rt.balanceOf(address(this));
        if (shares == 0) return 0;
        uint256 value = shares.rayMulDown(POOL.getNormalizedIncome(asset));
        uint256 amount = value < r.cash ? value : r.cash;
        if (amount == 0) return 0;
        assets = amount == value ? POOL.withdraw(asset, type(uint256).max, address(this)) : POOL.withdraw(asset, amount, address(this));
        emit Redeemed(asset, shares, assets);
    }

    // nonReentrant + keeper-only; the balance diff is the intended measurement of swap output.
    // slither-disable-start reentrancy-balance
    /// @notice Swap non-stable revenue into the stablecoin. `minOut` must be within `maxSlippageBps`
    ///         of the oracle-implied amount, and the swap must settle before `deadline`.
    function swapToStable(address tokenIn, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert LLErrors.DeadlineExpired();
        if (address(swapAdapter) == address(0) || address(oracle) == address(0)) revert LLErrors.ZeroAddress();
        if (tokenIn == STABLECOIN || amountIn == 0) revert LLErrors.InvalidParams();
        uint256 fair = amountIn.mulDivDown(oracle.getPrice(tokenIn), 10 ** IERC20Metadata(tokenIn).decimals());
        fair = fair.mulDivDown(10 ** IERC20Metadata(STABLECOIN).decimals(), oracle.getPrice(STABLECOIN));
        if (minOut < fair.bpsMulUp(MathLib.BPS - maxSlippageBps)) revert LLErrors.SlippageTooHigh();

        // Measure what actually arrived instead of trusting the adapter's return value.
        uint256 before = IERC20(STABLECOIN).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(address(swapAdapter), amountIn);
        uint256 reported = swapAdapter.swapExactIn(tokenIn, STABLECOIN, amountIn, minOut, address(this), deadline);
        IERC20(tokenIn).forceApprove(address(swapAdapter), 0);
        out = IERC20(STABLECOIN).balanceOf(address(this)) - before;
        if (out < minOut || out < reported) revert LLErrors.SlippageTooHigh();
        emit Swapped(tokenIn, amountIn, out);
    }
    // slither-disable-end reentrancy-balance

    /// @notice Splits a token balance. Staker share is paid only in the stablecoin and only while the
    ///         project token is live; otherwise it goes to the treasury. Permissionless.
    function distribute(address token) external nonReentrant {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;
        uint256 toReserve = bal.bpsMulDown(reserveShareBps);
        uint256 toStakers = 0;
        IProjectTokenHooks h = hooks;
        if (token == STABLECOIN && address(h) != address(0) && h.isActive()) {
            toStakers = bal.bpsMulDown(stakerShareBps);
        }
        uint256 toTreasury = bal - toReserve - toStakers;
        emit Distributed(token, toReserve, toStakers, toTreasury);

        if (toReserve > 0) IERC20(token).safeTransfer(reserve, toReserve);
        if (toTreasury > 0) IERC20(token).safeTransfer(treasury, toTreasury);
        if (toStakers > 0) {
            IERC20(token).forceApprove(address(h), toStakers);
            h.notifyReward(toStakers);
        }
    }
}
