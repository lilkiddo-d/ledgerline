# Decisions

One line of reasoning per decision. Newest decisions are grouped by area, not by date.

## Chain and assets

- **Robinhood Chain mainnet = chain 4663, gas token ETH, Blockscout explorer.** Taken from docs.robinhood.com and confirmed on-chain (`eth_chainId` = 0x1237).
- **USDG is the stablecoin market, not USDC.** No USDC token exists on the chain (Circle lists none). USDG (6 decimals) is the official stablecoin in the docs.
- **Launch listing: USDG + AAPL, MSFT, NVDA, GOOGL, META, AMZN, TSLA, SPY, QQQ.** Each has an official token *and* a Chainlink feed. NFLX was skipped because it has no feed, and we never list an asset we can't price.
- **Stock tokens are treated as plain 18-decimal ERC-20s.** ERC-8056 keeps raw balances fixed and moves a UI multiplier, so the tokens don't rebase. Chainlink prices already include the multiplier, so pool accounting stays correct.
- **The adapter honours `oraclePaused()`.** The issuer sets it during corporate actions (splits), and pricing a token while its oracle is paused is exactly when prices are wrong.
- **USD caps are converted to token caps at deploy-time prices.** Launch caps per stock are $2M supply and $500k borrow; USDG caps are 10M supply and 8M borrow. Small caps limit blast radius while the protocol is unaudited.

## Oracles

- **Chainlink is the only primary source.** It's the only oracle network named in the official docs. OracleAdapter accepts an optional secondary (deviation-checked) once a second source exists.
- **Staleness depends on market hours: 25h open, 4 days closed.** The 24/5 equity feeds stop heartbeating off-hours, and 4 days covers a long weekend plus a holiday. The open window rides on Chainlink's 24h heartbeat.
- **Sanity bands.** Stocks need a price above $0.01; stablecoins must sit in $0.50–$2.00. This catches broken feeds, not depegs: we don't want a de-peg circuit breaker to freeze every account.
- **Sequencer-uptime support is built but disabled.** Chainlink doesn't publish an uptime feed for this chain. Governance can enable the check if one is published.
- **The oracle is swappable via the Timelock.** The Pool only knows `IPriceOracle`, so moving to Data Streams or a median adapter needs no Pool migration.

## Risk engine

- **Every safety-reducing action is checked against LTV-based borrow power.** That covers borrow, withdraw, receipt transfer, disabling collateral and switching e-mode. Using LTV rather than HF ≥ 1 means the closed-market LTV cut actually binds on withdrawals too.
- **When the US market closes, only LTV is lowered; liquidation thresholds stay the same.** Otherwise every close would push accounts into liquidation. LTV changes only gate new risk.
- **Closed-market stock borrowing is capped at `closedBorrowCap`, 20% of the open borrow cap at launch.** This limits new shorts against stale prices.
- **MarketClock implements the US DST rules on-chain** (2nd Sunday of March to 1st Sunday of November). No keeper has to flip offsets twice a year. NYSE holidays and early closes for 2026–2027 are seeded at deploy; governance must extend the table yearly.
- **The default session is regular hours, 09:30–16:00 New York.** Overnight sessions are thin, and conservative is right for collateral. `setSchedule` can widen it to 24/5.
- **E-mode follows Aave semantics.** In a category, users may borrow only assets from that category, and only collateral from that category gets the boosted LTV and LT. The correlation assumption only holds within the basket.
- **Close factor is 50%, rising to 100% below HF 0.95.** This is the standard Aave/Compound design and limits over-liquidation.
- **Liquidation bonus is 5% for USDG, 6% for index ETFs, 8% for large caps and 10% for TSLA.** Each is scaled to the asset's volatility. `LT × (1 + bonus) < 100%` is enforced so a liquidation can always improve health.
- **10% of the bonus goes to the protocol (`liqProtocolFeeBps`).** It funds the Reserve while leaving liquidators enough incentive.
- **Bad debt is written off only when an account has no collateral left.** That is unambiguous and cheap to detect. The Reserve covers first, in kind; the remainder lowers the liquidity index (socialized).

## Accounting

- **Indices are in RAY. Supply and debt shares are non-rebasing.** Every rounding goes in the protocol's favour: supply shares round down, withdrawals burn shares rounded up, debt shares round up, and repayment burns round down.
- **Cash is tracked internally instead of read from `balanceOf`.** Donations then can't move rates or exchange rates, which kills the ERC-4626 inflation attack. `skim()` sends any excess to the FeeCollector.
- **Treasury share is accrued as unminted receipt shares (`accruedToTreasuryScaled`).** Protocol revenue stays as pool liquidity until harvested, Aave-style.
- **Flash loan fees (default 5 bps, max 1%) go to the treasury.** That keeps supplier accounting simple.
- **Global pause blocks everything except `repay`.** Users must always be able to de-risk. Liquidations also pause, because pauses usually mean prices can't be trusted.

## Architecture

- **The Pool is non-upgradeable.** Liquidation and flash-loan logic live in immutable delegatecall modules that share ERC-7201 namespaced storage. This keeps the Pool under 24KB without a proxy admin key, and the storage layout can't drift between modules.
- **Flash loans run under the Pool's reentrancy lock.** A borrower can't touch the Pool during the callback, which removes flash-loan manipulation of pool state entirely.
- **The rate model is immutable per instance, and `AssetConfig` points each asset at one.** A parameter change is a new deployment plus a Timelock call, accrued before the switch.
- **AssetConfig is a separate contract and the sole lister (it holds `CONFIGURATOR_ROLE` on the Pool).** It gives one place to read and validate all risk parameters.
- **The receipt token implements the ERC-4626 interface over Pool liquidity.** Integrators get a standard vault surface; `maxWithdraw` is an upper bound because health checks run at execution.
- **The custom error library is named `LLErrors`, not `Errors`.** Name reuse with OpenZeppelin v5's `Errors` silently broke Slither's IR generation for the Pool.

## Governance and roles

- **The Timelock has a 48h floor even against its own `updateDelay`.** `getMinDelay()` never returns less than 48h, so a malicious proposal can't shorten future delays.
- **The guardian can only tighten.** It can pause, freeze or pause a reserve, and force the market "closed". Only the Timelock can loosen any of these, so a compromised guardian can't make anything riskier.
- **Governance (Timelock proposer/executor) defaults to the deployer if `LEDGERLINE_GOVERNANCE` is unset.** That makes a single-signer deploy possible. DEPLOY.md strongly recommends passing a multisig.
- **The Reserve and ProjectTokenHooks are owned by the Timelock from construction.** They never have a deployer-admin window.

## Project token ($LEDG)

- **No token is written or deployed.** `setProjectToken(address)` on ProjectTokenHooks is owner-only (the Timelock) and one-shot. Until it is called, `isActive()` is false, staking reverts, discounts are 0 and the FeeCollector sends the staker share to the treasury.
- **The staker discount applies to the protocol's share of interest (reserve factor), funded from treasury accrual.** Suppliers are mathematically unaffected, which the tests and invariants check.
- **Discounts are applied lazily when a borrower's debt is touched (borrow, repay, liquidation).** That avoids per-user rates in a shared index. A 7-day unstake cooldown limits stake-just-before-repay gaming.
- **Default tiers are 1k → 10%, 10k → 25% and 100k → 50%, assuming 18 decimals.** They live in the constructor because the owner is the Timelock from birth. Governance can replace them.
- **Staking rewards are paid only in stablecoin.** Non-stable fees go to the Reserve and treasury in kind, or are swapped by the keeper first.

## Treasury

- **FeeCollector split: 20% Reserve, 30% stakers (when the token is live), the rest to the treasury.** Bad-debt protection builds up before token rewards do.
- **Swaps need `minOut` within `maxSlippageBps` (default 1%) of the oracle-implied amount, plus a deadline.** Output is measured by balance difference, not the adapter's return value. No DEX adapter is wired at launch because no DEX is documented on the chain; FeeCollector takes any `ISwapAdapter`.

## Compliance

- **ComplianceRegistry is deployed and wired but disabled.** When enabled it gates supply (by beneficiary), borrow, flash loans and incoming receipt transfers. It never gates repay, withdraw or liquidation, so users can always exit and solvency can't be held hostage.
- **Allowlist edits use `ALLOWLIST_MANAGER_ROLE`, not the Timelock.** Onboarding can't wait 48h. Turning the gate on or off is a Timelock action.
- **The frontend geoblock uses the `x-vercel-ip-country` header (Next 16 `proxy.ts`).** It is empty by default and configured with `GEOBLOCK_COUNTRIES`. It is a UI control only; the contracts stay permissionless unless the registry is enabled.
- **Branding: "Ledgerline" with a neutral gradient mark.** The network is named only factually (chain config and docs), never as branding.

## Deployment and tooling

- **The deploy script is signer-agnostic and never touches keys.** Production uses `--account ledgerline-deployer` (Foundry keystore). The anvil fork run uses `--unlocked` with anvil's `--auto-impersonate`, so no key exists for that run either.
- **There is no CREATE2 factory, so contracts deploy with plain CREATE.** The Arachnid deployer has no code on 4663; CreateX exists but isn't documented.
- **`deployedAtBlock` is read via `eth_blockNumber`.** On Arbitrum-based chains `block.number` returns the L1 block, which would break event scans.
- **Dry runs write `deployments/<name>.dryrun.json` and never touch the frontend config.** Broadcast runs write `deployments/<name>.json` and `app/src/generated/deployment.json`.
- **Fork tests fork the live RPC at head instead of a long-lived anvil.** The public RPC isn't an archive node, so state at a pinned fork block is pruned after about 30 minutes.
- **`RobinhoodDeployment.sol` is shared by `Deploy.s.sol` and the fork tests.** Fork tests then exercise the exact production deploy path. Instantiating the script contract in a test exceeds EIP-3860 initcode limits.
- **The frontend is Next 16, wagmi 2 and RainbowKit 2.** RainbowKit 2.2 peers on wagmi ^2.9, so wagmi 3 is deliberately not used.
- **A dev-only `mock` connector exists for an impersonated anvil account.** It is enabled only when `NEXT_PUBLIC_DEV_MOCK_ACCOUNT` is set and the RPC is localhost, so the fork can be driven end-to-end without any private key.
- **The liquidations page scans `Borrow` events in 200k-block chunks, up to 10M blocks back.** That is enough for a UI. Production liquidators should run an indexer and a bot (docs/LIQUIDATIONS.md).
