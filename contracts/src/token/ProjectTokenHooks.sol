// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {MathLib} from "../libraries/MathLib.sol";
import {LLErrors} from "../libraries/LLErrors.sol";
import {IProjectTokenHooks} from "../interfaces/IProjectTokenHooks.sol";

/// @title ProjectTokenHooks
/// @notice Everything that touches the (separately launched) $LEDG token. No token is deployed by
///         this protocol: the owner (the Timelock) calls `setProjectToken` exactly once. Until then
///         every feature here is inert: `isActive()` is false, staking reverts, discounts are 0, and
///         the FeeCollector routes the staker share to the treasury instead.
///
///         Features:
///         - Staking: stake $LEDG, earn a pro-rata share of reserve-factor revenue paid in stablecoin.
///         - Borrow-rate discount tiers: stakers get a rebate on the protocol's share of their interest.
///         Unstaking has a cooldown, so stake can't be flashed in right before a repay to farm discounts.
contract ProjectTokenHooks is IProjectTokenHooks, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    uint256 public constant MAX_TIERS = 4;
    uint256 public constant MAX_DISCOUNT_BPS = 5_000;
    uint256 private constant PRECISION = 1e36;

    IERC20 public immutable REWARD_TOKEN; // stablecoin
    address public immutable FEE_COLLECTOR;

    IERC20 public projectToken;
    uint256 public cooldown = 7 days;

    struct Tier {
        uint128 minStake;
        uint16 discountBps;
    }

    Tier[] private _tiers;

    uint256 public totalStaked;
    uint256 public rewardPerTokenStored;
    uint256 public queuedRewards; // rewards received while nobody was staked
    mapping(address => uint256) public staked;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public pendingUnstake;
    mapping(address => uint256) public unstakeReadyAt;

    event ProjectTokenSet(address indexed token);
    event TiersUpdated(uint128[] minStakes, uint16[] discountBps);
    event CooldownUpdated(uint256 cooldown);
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 readyAt);
    event Unstaked(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint256 rewardPerToken);
    event RewardClaimed(address indexed user, uint256 amount);

    constructor(address owner_, IERC20 rewardToken, address feeCollector) Ownable(owner_) {
        if (address(rewardToken) == address(0) || feeCollector == address(0)) revert LLErrors.ZeroAddress();
        REWARD_TOKEN = rewardToken;
        FEE_COLLECTOR = feeCollector;
        // Default tiers (assumes 18-decimal token); governance can replace them via the Timelock.
        uint128[] memory m = new uint128[](3);
        uint16[] memory b = new uint16[](3);
        (m[0], m[1], m[2]) = (1_000e18, 10_000e18, 100_000e18);
        (b[0], b[1], b[2]) = (1_000, 2_500, 5_000);
        _setTiers(m, b);
    }

    // ---------------- governance ----------------

    /// @notice One-shot activation. Callable by the owner (Timelock) once; irreversible.
    function setProjectToken(address token) external onlyOwner {
        if (address(projectToken) != address(0)) revert LLErrors.AlreadySet();
        if (token == address(0) || token.code.length == 0 || token == address(REWARD_TOKEN)) revert LLErrors.InvalidParams();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    /// @notice Ascending tiers, at most MAX_TIERS.
    function setTiers(uint128[] calldata minStakes, uint16[] calldata discountBps) external onlyOwner {
        _setTiers(minStakes, discountBps);
    }

    function _setTiers(uint128[] memory minStakes, uint16[] memory discountBps) private {
        uint256 n = minStakes.length;
        if (n != discountBps.length || n > MAX_TIERS) revert LLErrors.InvalidParams();
        delete _tiers;
        for (uint256 i; i < n; ++i) {
            if (discountBps[i] > MAX_DISCOUNT_BPS || minStakes[i] == 0) revert LLErrors.InvalidParams();
            if (i > 0 && (minStakes[i] <= minStakes[i - 1] || discountBps[i] < discountBps[i - 1])) {
                revert LLErrors.InvalidParams();
            }
            _tiers.push(Tier(minStakes[i], discountBps[i]));
        }
        emit TiersUpdated(minStakes, discountBps);
    }

    function setCooldown(uint256 c) external onlyOwner {
        if (c < 1 days || c > 30 days) revert LLErrors.InvalidParams();
        cooldown = c;
        emit CooldownUpdated(c);
    }

    // ---------------- views ----------------

    function isActive() public view returns (bool) {
        return address(projectToken) != address(0);
    }

    function tiers() external view returns (Tier[] memory) {
        return _tiers;
    }

    function borrowDiscountBps(address account) external view returns (uint256 d) {
        if (!isActive()) return 0;
        uint256 s = staked[account];
        uint256 n = _tiers.length;
        for (uint256 i; i < n; ++i) {
            if (s >= _tiers[i].minStake) d = _tiers[i].discountBps;
        }
    }

    function earned(address account) public view returns (uint256) {
        return rewards[account]
            + staked[account].mulDivDown(rewardPerTokenStored - userRewardPerTokenPaid[account], PRECISION);
    }

    // ---------------- staking ----------------

    modifier whenActive() {
        if (!isActive()) revert LLErrors.NotActive();
        _;
    }

    modifier updateReward(address account) {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }

    function stake(uint256 amount) external nonReentrant whenActive updateReward(msg.sender) {
        if (amount == 0) revert LLErrors.ZeroAmount();
        uint256 before = projectToken.balanceOf(address(this));
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = projectToken.balanceOf(address(this)) - before; // fee-on-transfer safe
        staked[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
        _flushQueued();
    }

    /// @notice Stops earning and loses discount immediately; tokens claimable after the cooldown.
    function requestUnstake(uint256 amount) external nonReentrant whenActive updateReward(msg.sender) {
        if (amount == 0 || amount > staked[msg.sender]) revert LLErrors.InsufficientBalance();
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        pendingUnstake[msg.sender] += amount;
        uint256 readyAt = block.timestamp + cooldown;
        unstakeReadyAt[msg.sender] = readyAt;
        emit UnstakeRequested(msg.sender, amount, readyAt);
    }

    function withdrawUnstaked() external nonReentrant whenActive {
        uint256 amount = pendingUnstake[msg.sender];
        if (amount == 0) revert LLErrors.ZeroAmount();
        if (block.timestamp < unstakeReadyAt[msg.sender]) revert LLErrors.Cooldown();
        pendingUnstake[msg.sender] = 0;
        emit Unstaked(msg.sender, amount);
        projectToken.safeTransfer(msg.sender, amount);
    }

    function claim() external nonReentrant updateReward(msg.sender) returns (uint256 amount) {
        amount = rewards[msg.sender];
        if (amount == 0) return 0;
        rewards[msg.sender] = 0;
        emit RewardClaimed(msg.sender, amount);
        REWARD_TOKEN.safeTransfer(msg.sender, amount);
    }

    /// @notice Called by the FeeCollector with the stakers' share of revenue.
    function notifyReward(uint256 amount) external nonReentrant {
        if (msg.sender != FEE_COLLECTOR) revert LLErrors.OnlyPool();
        if (amount == 0) return;
        REWARD_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        queuedRewards += amount;
        _flushQueued();
    }

    function _flushQueued() private {
        uint256 q = queuedRewards;
        if (q == 0 || totalStaked == 0) return;
        queuedRewards = 0;
        rewardPerTokenStored += q.mulDivDown(PRECISION, totalStaked);
        emit RewardNotified(q, rewardPerTokenStored);
    }
}
