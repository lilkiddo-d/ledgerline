# Ledgerline

A pooled money market on **Robinhood Chain** (chain 4663) for stablecoins and tokenized stocks. Supply USDG or stock tokens to earn interest. Borrow USDG against stock collateral, or borrow stock tokens to go short. Each stock has its own isolated risk settings, and the stablecoin pool is shared.

> **Status: unaudited.** Read [THREAT_MODEL.md](THREAT_MODEL.md) before deploying meaningful value.

## Features

- **Isolated risk per stock:** LTV, liquidation threshold and bonus, reserve factor, supply and borrow caps, a closed-market LTV and a closed-market borrow cap.
- **Interest:** a kinked utilization rate model per asset. ERC-4626-style interest-bearing receipt tokens; non-transferable variable debt tracked by a RAY index.
- **Health and liquidation:** health factor per account; permissionless liquidations with a 50%/100% close factor and a liquidation bonus. Bad debt is covered by the Reserve first, then socialized.
- **Market-hours guard:** `MarketClock` encodes US DST on-chain plus NYSE holidays and early closes. While the market is closed, stock LTVs drop and new stock borrowing is capped.
- **E-mode** for correlated baskets (launch: "US Tech" at 75% LTV / 80% LT).
- **ERC-3156 flash loans** with a fee. The Pool stays locked during the callback.
- **Swappable OracleAdapter** over Chainlink. It checks staleness by market session, round completeness, sanity bands, the issuer's `oraclePaused()`, an optional secondary-source deviation check and an optional sequencer-uptime check.
- **Governance:** AccessControl behind a 48h Timelock with an enforced floor, plus a guardian that can only tighten (pause, freeze, force the market closed).
- **ComplianceRegistry** allowlist hook, off by default. Optional frontend geoblock and a risk-disclosure gate.
- **$LEDG hooks:** staking for a share of revenue (paid in USDG) and borrow-discount tiers. Inert until `setProjectToken` is executed through the Timelock; no token is deployed here. See [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).

## Repository

```
contracts/   Foundry project (Solidity 0.8.28, OpenZeppelin v5.4)
  src/core/        Pool, PoolBase, LiquidationLogic, FlashLoan, AssetConfig, InterestRateModel, ReceiptToken, DebtToken
  src/risk/        MarketClock, OracleAdapter
  src/treasury/    Reserve, FeeCollector
  src/token/       ProjectTokenHooks
  src/governance/  Timelock
  src/compliance/  ComplianceRegistry
  src/periphery/   PoolLens (frontend reads)
  script/          Deploy.s.sol (production), RobinhoodDeployment.sol, DeployCore.sol, SeedFork.s.sol (local only)
  test/            unit/, fuzz/, invariant/, fork/
app/         Next.js 16 + wagmi 2 + viem + RainbowKit frontend
config/      chains.ts: chain + official token and feed addresses with source links
scripts/     ABI export, fork snapshot tooling
deployments/ <name>.json written by the deploy script
docs/        SLITHER.md, LIQUIDATIONS.md, full Slither report
```

## Architecture

```
                    ┌─────────────── Timelock (48h) ────────────────┐ guardian: pause / freeze only
                    │ admin of everything below                     │
 users ──► Pool ────┼── delegatecall ──► LiquidationLogic, FlashLoan│ (shared ERC-7201 storage)
   ▲        │  ▲    │                                               │
   │        │  └────┼── AssetConfig (risk params, e-mode, IRM ptrs) │
   │        ├──────►│   OracleAdapter ─► Chainlink feeds (24/5)     │
   │        ├──────►│   MarketClock (session, DST, holidays)        │
   │        ├──────►│   ComplianceRegistry (off by default)         │
   │        ├──────►│   ProjectTokenHooks (inert until token set)   │
   │        │       └───────────────────────────────────────────────┘
 ReceiptToken (ERC-4626 shares) / DebtToken (scaled, non-transferable) per asset
   protocol fees ─► FeeCollector ─► Reserve (bad debt) · stakers (USDG) · treasury
```

## Quickstart

```bash
# contracts
cd contracts
forge build --sizes
forge test                                    # unit + fuzz + invariant (fork suite skips without RPC)
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*"
forge coverage --report summary --no-match-coverage "(test|script)"
slither .                                     # 0 high / 0 medium, see docs/SLITHER.md

# frontend against a local mainnet snapshot
cd .. && pnpm install
bash scripts/fork-snapshot.sh                 # terminal 1: deploy + seed + serve on :8711
printf 'NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8711\nNEXT_PUBLIC_DEV_MOCK_ACCOUNT=0x00000000000000000000000000000000000000A2\n' > app/.env.local
pnpm abis && pnpm app:build && pnpm app:start  # terminal 2: http://localhost:3100
```

Deploying to mainnet: see [DEPLOY.md](DEPLOY.md).

## Launch markets

| Asset | Tier | LTV / LT | Closed-market LTV | Bonus | Reserve factor | E-mode |
|---|---|---|---|---|---|---|
| USDG | stablecoin | 80% / 85% | n/a | 5% | 10% | n/a |
| AAPL, MSFT, NVDA, GOOGL, META, AMZN | large cap | 60% / 70% | 40% | 8% | 20% | US Tech (75% / 80%, 5%) |
| SPY, QQQ | index ETF | 70% / 78% | 50% | 6% | 20% | n/a |
| TSLA | high volatility | 50% / 60% | 30% | 10% | 20% | n/a |

Launch caps per stock are $2M supply and $500k borrow (converted to tokens at deploy prices). The closed-market borrow cap is 20% of the borrow cap. USDG caps are 10M supply and 8M borrow.

Rate models: USDG is 0% → 6% at 90% utilization → 66% at 100%. Stocks are 2% → 12% at 50% utilization → 162% at 100%.

## Verification status (at handoff)

| Check | Result |
|---|---|
| Unit + fuzz + invariant tests | 97 passed, 0 failed (5 fork tests skip without an RPC URL) |
| Fork tests (live USDG, AAPL, NVDA, MSFT + Chainlink) | 5 passed |
| Line coverage, core contracts | 98.7–100% (see below) |
| Slither high/medium | 0 |
| Anvil fork deploy (broadcast) | succeeded |
| Mainnet dry run (no broadcast) | `SIMULATION COMPLETE`, ~65.2M gas, ~0.0026 ETH |
| Frontend `next build` | passes (TypeScript strict) |
| Frontend end-to-end on mainnet fork | markets, account, supply, borrow and liquidation all confirmed on-chain |

## Documents

- [DEPLOY.md](DEPLOY.md): exactly what to run.
- [DECISIONS.md](DECISIONS.md): every judgement call, one line each.
- [THREAT_MODEL.md](THREAT_MODEL.md): oracle manipulation, weekend gaps, rounding, flash loans, governance.
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md): how $LEDG plugs in later.
- [docs/SLITHER.md](docs/SLITHER.md) and [docs/LIQUIDATIONS.md](docs/LIQUIDATIONS.md).

Ledgerline is independent software and is not affiliated with, or endorsed by, the operator of Robinhood Chain or any token issuer.
