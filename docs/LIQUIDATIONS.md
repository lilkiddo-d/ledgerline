# Liquidations

## Rules (on-chain)

- An account is liquidatable when `healthFactor < 1.0`, where `HF = Σ(collateral × liquidation threshold) / Σ(debt)` at oracle prices. E-mode thresholds apply where relevant.
- **Close factor:** up to 50% of one debt asset per call, or 100% once `HF < 0.95`.
- **Bonus:** the liquidator receives `repaid × (1 + bonus)` worth of collateral. 10% of the bonus is taken as a protocol fee and sent to the FeeCollector.
- **Delivery:** collateral arrives either as the underlying token (needs pool cash) or as receipt tokens (`receiveReceipt = true`, works at 100% utilization).
- **Bad debt:** if a liquidation leaves the account with zero collateral but non-zero debt, all remaining debt is written off. The Reserve covers what it can, and the rest is socialized through the supply index.
- **Market hours do not change liquidation thresholds.** Only LTV drops while the market is closed.
- Liquidations can't be gated by the compliance registry. They are blocked by a global pause or a paused reserve, and by stale or paused oracles.

## Running a liquidator

The `/liquidations` page in the app scans `Borrow` events directly from the RPC (in 200k-block chunks) and batch-reads health factors with `PoolLens.getHealthFactors`. That is fine for manual use. For production:

1. **Index borrowers.** Subscribe to `Borrow`, `Repay`, `Liquidation` and `BadDebtWrittenOff` from the Pool, starting at `deployedAtBlock` in `deployments/4663.json`.
2. **Poll health.** Call `PoolLens.getHealthFactors(address[])` in batches each block, or on every Chainlink `AnswerUpdated` for listed feeds.
3. **Size the call.** Use `PoolLens.getUserPositions(user)` and pick the collateral with the largest value and the debt with the largest value. Pass `type(uint256).max` as `debtToCover` to take the maximum allowed.
4. **Fund it.** Hold inventory of the debt asset, or flash-borrow it from another venue. Ledgerline's own flash loans can't fund a Ledgerline liquidation because the Pool stays locked during the callback. This is deliberate: see THREAT_MODEL.md §4.
5. **Watch the market opens.** The highest-risk moment is the first oracle update after a weekend or holiday (price gaps). Run with extra capacity at 09:30 New York time.
