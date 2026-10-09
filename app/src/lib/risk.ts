import { toNum, wadToNum } from "./format";

export type MarketLike = {
  asset: string;
  decimals: number;
  priceWad: bigint;
  params: { ltvBps: number; liqThresholdBps: number; eModeCategory: number; isStock: boolean; closedLtvBps: number; collateralEnabled: boolean };
};

export type PositionLike = { asset: string; supplied: bigint; borrowed: bigint; collateral: boolean };

export type EMode = { ltvBps: number; liqThresholdBps: number } | undefined;

export function effectiveLt(m: MarketLike, userEMode: number, emode: EMode) {
  if (userEMode !== 0 && m.params.eModeCategory === userEMode && emode) return emode.liqThresholdBps / 10_000;
  return m.params.liqThresholdBps / 10_000;
}

export function effectiveLtv(m: MarketLike, userEMode: number, emode: EMode, marketOpen: boolean) {
  if (!m.params.collateralEnabled) return 0;
  let ltv = m.params.ltvBps;
  if (userEMode !== 0 && m.params.eModeCategory === userEMode && emode) ltv = emode.ltvBps;
  if (m.params.isStock && !marketOpen) ltv = Math.min(ltv, m.params.closedLtvBps);
  return ltv / 10_000;
}

type Totals = { weighted: number; debt: number; power: number };

export function totals(markets: MarketLike[], positions: PositionLike[], userEMode: number, emode: EMode, open: boolean): Totals {
  let weighted = 0, debt = 0, power = 0;
  for (const p of positions) {
    const m = markets.find((x) => x.asset.toLowerCase() === p.asset.toLowerCase());
    if (!m) continue;
    const price = wadToNum(m.priceWad);
    if (p.collateral) {
      const v = toNum(p.supplied, m.decimals) * price;
      weighted += v * effectiveLt(m, userEMode, emode);
      power += v * effectiveLtv(m, userEMode, emode, open);
    }
    debt += toNum(p.borrowed, m.decimals) * price;
  }
  return { weighted, debt, power };
}

export type Action = "supply" | "withdraw" | "borrow" | "repay";

/** Health factor after a hypothetical action (Infinity when there is no debt). */
export function projectedHf(
  markets: MarketLike[],
  positions: PositionLike[],
  userEMode: number,
  emode: EMode,
  open: boolean,
  action: Action,
  asset: string,
  amount: number,
): number {
  const t = totals(markets, positions, userEMode, emode, open);
  const m = markets.find((x) => x.asset.toLowerCase() === asset.toLowerCase());
  if (!m) return t.debt === 0 ? Infinity : t.weighted / t.debt;
  const pos = positions.find((p) => p.asset.toLowerCase() === asset.toLowerCase());
  const usd = amount * wadToNum(m.priceWad);
  const isColl = pos?.collateral || ((pos?.supplied ?? 0n) === 0n && m.params.collateralEnabled);
  const lt = effectiveLt(m, userEMode, emode);
  if (action === "supply" && isColl) t.weighted += usd * lt;
  if (action === "withdraw" && pos?.collateral) t.weighted -= usd * lt;
  if (action === "borrow") t.debt += usd;
  if (action === "repay") t.debt = Math.max(0, t.debt - usd);
  return t.debt <= 0 ? Infinity : Math.max(0, t.weighted) / t.debt;
}

/**
 * Price of `asset` at which the account's health factor reaches 1, holding everything else fixed.
 * Collateral: price falling to this level triggers liquidation. Debt (short): price rising to it does.
 */
export function liquidationPrice(
  markets: MarketLike[],
  positions: PositionLike[],
  userEMode: number,
  emode: EMode,
  open: boolean,
  asset: string,
): number | null {
  const t = totals(markets, positions, userEMode, emode, open);
  const m = markets.find((x) => x.asset.toLowerCase() === asset.toLowerCase());
  const p = positions.find((x) => x.asset.toLowerCase() === asset.toLowerCase());
  if (!m || !p || t.debt === 0) return null;
  const price = wadToNum(m.priceWad);
  const lt = effectiveLt(m, userEMode, emode);
  const collQty = p.collateral ? toNum(p.supplied, m.decimals) : 0;
  const debtQty = toNum(p.borrowed, m.decimals);
  const otherWeighted = t.weighted - collQty * price * lt;
  const otherDebt = t.debt - debtQty * price;
  // HF = 1 <=> otherWeighted + q_c * P * lt = otherDebt + q_d * P
  const denom = collQty * lt - debtQty;
  if (Math.abs(denom) < 1e-12) return null;
  const liq = (otherDebt - otherWeighted) / denom;
  return liq > 0 ? liq : null;
}

export function hfColor(hf: number): string {
  if (!Number.isFinite(hf) || hf >= 2) return "var(--good)";
  if (hf >= 1.2) return "var(--warn)";
  return "var(--bad)";
}
