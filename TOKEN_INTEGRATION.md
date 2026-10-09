# $LEDG token integration

Ledgerline does **not** write, deploy or mint any ERC-20 for the project token. $LEDG launches separately on a launchpad. This document covers how the protocol plugs into it afterwards.

## What exists at deploy time

`ProjectTokenHooks` (contracts/src/token/ProjectTokenHooks.sol) is deployed, wired and owned by the **Timelock** from construction. The project-token address is unset, so:

| Feature | Before `setProjectToken` | After |
|---|---|---|
| `isActive()` | `false` | `true` |
| Staking (`stake`, `requestUnstake`, `withdrawUnstaked`) | reverts `NotActive` | enabled |
| Borrow discount (`borrowDiscountBps`) | always `0` | tiered by stake |
| FeeCollector staker share (30%) | sent to the treasury | sent to stakers in USDG |
| Frontend `/stake` page | hidden | shown when `NEXT_PUBLIC_PROJECT_TOKEN` is set |

The protocol works fully without the token: lending, borrowing, liquidations, flash loans and fees are all independent of it.

## Activating (after the launchpad token exists)

`setProjectToken(address)` is owner-only and **callable exactly once**. It rejects the zero address, addresses without code and the stablecoin. Because the owner is the Timelock, it is a two-step, 48h governance action:

```bash
# 1. schedule (governance multisig / proposer)
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $HOOKS 0 $(cast calldata "setProjectToken(address)" $LEDG) 0x0 0x0 172800 \
  --account <proposer> --rpc-url https://rpc.mainnet.chain.robinhood.com

# 2. after 48h, execute (executor)
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $HOOKS 0 $(cast calldata "setProjectToken(address)" $LEDG) 0x0 0x0 \
  --account <executor> --rpc-url https://rpc.mainnet.chain.robinhood.com
```

DEPLOY.md has the copy-paste version with the addresses filled in from `deployments/4663.json`.

Then set `NEXT_PUBLIC_PROJECT_TOKEN=<LEDG address>` in Vercel and redeploy the frontend.

## Staking: revenue share in stablecoin

- Stake $LEDG to earn a pro-rata share of the stakers' cut (default **30%**) of protocol revenue. That revenue is reserve-factor interest, liquidation protocol fees and flash-loan fees.
- Revenue flows `Pool → FeeCollector.harvest → (optional keeper swap to USDG) → FeeCollector.distribute → ProjectTokenHooks.notifyReward`.
- Rewards use a reward-per-token accumulator. Rewards that arrive while nobody is staked are queued and released to the first stakers.
- Fee-on-transfer tokens are handled: stake credits what actually arrived.
- **Unstaking** happens in two steps. `requestUnstake(amount)` stops rewards and the discount immediately; `withdrawUnstaked()` works after the cooldown (default 7 days, adjustable to 1–30 days by the Timelock).

## Borrow-rate discount tiers

| Staked $LEDG (default, assumes 18 decimals) | Discount on the protocol's share of your interest |
|---|---|
| ≥ 1,000 | 10% |
| ≥ 10,000 | 25% |
| ≥ 100,000 | 50% (max allowed) |

The Timelock can replace the tiers (`setTiers`, ≤ 4 tiers, ascending, ≤ 50% each).

**How the discount works.** The pool uses one shared borrow index per asset, so per-user rates don't exist. Instead, whenever your debt is touched (borrow, repay, or liquidation), the Pool computes the interest you accrued since your last touch. It then rebates `interest × reserveFactor × discount`, reducing your debt and the treasury's accrued share by the same amount.

- **Suppliers are never affected.** The rebate comes only out of the protocol's share; the test `test_borrowDiscount_endToEnd` and the solvency invariant check this.
- **Stake timing.** The discount uses your stake *at the time of the touch*. The unstake cooldown makes "stake right before repaying" expensive, and THREAT_MODEL.md covers the residual risk.
- **Hook failures** are caught. A reverting hooks contract never blocks a repay or liquidation; the discount is simply 0.

## Frontend

- `NEXT_PUBLIC_PROJECT_TOKEN` empty or unset → the Stake nav link and page are hidden.
- Set but not yet activated on-chain → `/stake` explains the token is not active yet.
- Activated → stake, request unstake, withdraw and claim; the page shows your discount tier and claimable USDG.

## Testing

Tests use a **mock ERC-20 only** (`test/mocks/MockERC20.sol`). See `test/unit/TreasuryAndToken.t.sol`: `ProjectTokenHooksTest` and `GovernanceTest.test_timelock_setProjectToken_after48h`.
