# Threat model

Scope covers `contracts/src/**`, the deploy script and the frontend's trust assumptions. Status: **unaudited**. Before mainnet TVL grows, commission an external audit and a formal-verification pass over the accounting invariants.

## Assets at risk

| Asset | Where it lives |
|---|---|
| Supplier liquidity (USDG, stock tokens) | `Pool` (tracked `cash`) |
| Borrower collateral | `Pool`, represented by `ReceiptToken` shares |
| Protocol revenue | `accruedToTreasuryScaled` → `FeeCollector` → `Reserve` / treasury / stakers |
| Bad-debt backstop | `Reserve` |
| Staked $LEDG and staking rewards | `ProjectTokenHooks` |

## Actors and trust

| Actor | Powers | Trust |
|---|---|---|
| Timelock (48h, floor enforced) | All admin: listings, risk params, oracle, clock, compliance switch, unpause, reserve withdrawals, `setProjectToken` | Trusted. Proposer and executor should be a multisig. |
| Guardian | Pause the Pool, freeze or pause reserves, force the market closed | Semi-trusted. Can only make things more conservative. |
| Allowlist manager | Edit the allowlist (only matters while the registry is enabled) | Semi-trusted. Can't touch funds. |
| Keeper | `FeeCollector.swapToStable` within the oracle slippage bound | Semi-trusted. Worst case: up to `maxSlippageBps` (≤5%) value leakage per swap. |
| Oracle (Chainlink) | Prices | Trusted with checks (see 1). |
| Stock-token issuer | Can pause token transfers and the oracle; sets the corporate-action multiplier | External dependency (see 6). |
| Users / liquidators / flash borrowers | Permissionless | Untrusted. |

## Top risks and mitigations

### 1. Oracle manipulation and failure

**Threats:** a manipulated or stale price lets an attacker borrow against inflated collateral, or liquidate healthy accounts. A broken feed (zero, negative or stale answer) bricks accounts or misprices them.

**Mitigations**
- Prices come from Chainlink aggregators, never from DEX spot prices. Flash-loan-sized trades can't move them.
- `OracleAdapter` rejects `answer <= 0`, `updatedAt == 0`, future timestamps, incomplete rounds (`answeredInRound < roundId`) and anything older than `maxAgeOpen` or `maxAgeClosed`. The closed-market window is longer because the 24/5 feeds stop heartbeating off-hours.
- Sanity bands: each asset has a `[minPrice, maxPrice]`. Stablecoins are bounded to $0.50–$2.00 to catch broken feeds.
- An optional secondary source adds a deviation check (`maxDeviationBps`) and falls back when one source fails.
- `oraclePaused()` on the stock token, set during corporate actions, makes the adapter refuse to price.
- A sequencer-uptime check with a grace period is implemented. It is disabled because no feed exists for chain 4663 yet.
- The adapter sits behind `IPriceOracle` and the Timelock can swap it.

**Residual risk:** there is only one oracle network. A Chainlink fault inside the staleness window is trusted. The guardian's pause and freeze are the response tool.

### 2. Weekend and overnight price gaps

**Threats:** stock prices freeze while the US market is closed and gap at the open. Positions can jump straight past their liquidation threshold into bad debt, and attackers can open positions against stale prices.

**Mitigations**
- `MarketClock` applies US DST rules on-chain and carries NYSE holiday and early-close tables. The guardian can force the market closed, for example during a trading halt.
- While closed, stock LTV is capped at `closedLtvBps` (30–50% vs 50–70% when open). This gates new borrows, withdrawals, collateral toggles and receipt transfers.
- New stock borrowing (shorts) while closed is limited to `closedBorrowCap`, 20% of the open cap at launch.
- Liquidation thresholds stay the same at the close, so the close itself never triggers mass liquidations.
- Conservative launch caps ($2M supply / $500k borrow per stock) bound total exposure.
- Bad debt goes to the Reserve first and is then socialized explicitly, so the accounting never breaks.

**Residual risk:** a gap larger than `1/LT − 1 − bonus` (roughly 30%+ for large caps) creates bad debt. That is inherent to collateralizing 5-day assets with a 7-day chain.

### 3. Interest-index rounding

**Threats:** an attacker repeats tiny operations so rounding drifts in their favour, extracting value or making claims exceed assets.

**Mitigations**
- Every conversion names its rounding direction (`MathLib`), and each one favours the protocol: supply shares round down, withdrawals burn shares rounded up, borrows mint debt rounded up, repays burn debt rounded down, and supplier interest is credited rounded down (debt before rounded up, debt after rounded down).
- Bad-debt socialization lowers the index rounding up, so claims fall by at least the loss.
- Indices are RAY (1e27) in `uint128`, which allows a 3.4e11× index before overflow.
- Invariant tests (handler with supply, withdraw, borrow, repay, liquidate, flash loan, warp and price shocks) assert: `cash + debt >= supplier claims`; `debt <= supply` up to op-count dust; the sum of all receipt values `<= totalSupplyAssets`; full withdrawals return exactly `convertToAssets(shares)`; and no healthy account is ever liquidated.
- A fuzz test asserts supply-then-withdraw never returns more than was supplied.

### 4. Flash-loan attacks

**Threats:** borrowed liquidity is used to manipulate prices, exchange rates or governance within one transaction.

**Mitigations**
- Prices come from oracles, not pool balances. Exchange rates come from internal indices; `cash` ignores donations, so the ERC-4626 inflation attack fails.
- `flashLoan` runs under the Pool's `nonReentrant` lock, so the receiver can't supply, borrow, liquidate or toggle collateral during the callback. The fee is booked before any external call (CEI).
- There is no token-weighted on-chain voting. Governance is the Timelock plus a multisig. $LEDG staking only affects rewards and discounts, and the 7-day unstake cooldown stops flash-staked tokens from claiming them.

### 5. Reentrancy and external calls

- Every Pool entry point is `nonReentrant`, including the receipt-transfer hook and `accrue`. The delegatecall modules run inside that lock.
- External calls during accounting go only to protocol-owned contracts with no callbacks (receipt/debt tokens, rate model, AssetConfig, oracle). Untrusted token transfers come last.
- The staker-discount hook call is wrapped in try/catch and capped at 100%. A broken hooks contract can never block repay or liquidation.
- Slither high and medium findings are fixed or triaged with justification (docs/SLITHER.md).

### 6. Stock-token issuer dependencies

- The issuer can **pause transfers**. Supply, withdraw, liquidation and repay in that asset then revert. The guardian should freeze the reserve. Liquidations against *other* collateral keep working.
- During **corporate actions** the token's `oraclePaused()` blocks pricing. Accounts holding that asset can't borrow or withdraw and can't be liquidated until it clears.
- ERC-8056 multiplier changes don't rebase balances, and Chainlink prices include the multiplier, so the accounting stays consistent.
- Fork tests confirm the live tokens transfer into and out of the Pool without an allowlist.

### 7. Governance and key compromise

- The 48h delay can't be lowered: `getMinDelay()` enforces a floor even after `updateDelay`.
- The guardian can only tighten (pause, freeze, force closed). Unpausing, unfreezing and reopening need the Timelock.
- `setProjectToken` works exactly once and rejects EOAs, the zero address and the stablecoin.
- Deployer roles are renounced in the same deploy script, and the script's postflight asserts it.
- Parameter bounds hold even for a malicious Timelock proposal: LTV ≤ LT < 100%, `LT × (1 + bonus) < 100%`, bonus ≤ 20%, reserve factor ≤ 50%, flash fee ≤ 1%, rate model ≤ 1000% APR, discount ≤ 50%.

### 8. Liveness and denial of service

- Loops are bounded: at most 32 reserves, holiday batches ≤ 64, allowlist batches ≤ 200, discount tiers ≤ 4.
- If an oracle reverts, health checks for affected accounts revert. Repay and supply still work.
- At 100% utilization, withdrawals wait until borrowers repay. The kinked rate model (slope up to +60–150%) pushes them to repay.
- Liquidators can take collateral as receipt tokens when pool cash is short.

### 9. Frontend

- The UI is a convenience layer. All limits are enforced on-chain.
- The geoblock is a best-effort header check. The on-chain ComplianceRegistry is the enforceable control.
- The dev mock connector works only with a localhost RPC and an explicit env var.

## Out of scope / accepted

- Chain-level risks: sequencer censorship or outage, L1 reorgs, bridge failures.
- USDG depeg. It is priced at the oracle and not frozen. Governance can cut its LTV or freeze it.
- MEV on liquidations. It is competitive by design; liquidators bring their own protection.
