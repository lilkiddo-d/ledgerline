import { formatUnits } from "viem";

const RAY = 10n ** 27n;
const WAD = 10n ** 18n;

export function toNum(v: bigint, decimals: number): number {
  return Number(formatUnits(v, decimals));
}

/** Annual rate (RAY) -> APY with continuous compounding approximation. */
export function rayToApy(rateRay: bigint): number {
  const apr = Number((rateRay * 1_000_000n) / RAY) / 1_000_000;
  return Math.expm1(apr);
}

export function rayToPct(v: bigint): number {
  return Number((v * 1_000_000n) / RAY) / 10_000;
}

export function wadToNum(v: bigint): number {
  return Number(formatUnits(v, 18));
}

export const MAX_UINT = 2n ** 256n - 1n;

export function fmtUsd(n: number, compact = false): string {
  if (!Number.isFinite(n)) return "-";
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    notation: compact && Math.abs(n) >= 100_000 ? "compact" : "standard",
    maximumFractionDigits: n !== 0 && Math.abs(n) < 1 ? 4 : 2,
  }).format(n);
}

export function fmtAmount(n: number, max = 4): string {
  if (!Number.isFinite(n)) return "-";
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: n !== 0 && Math.abs(n) < 1 ? 6 : max }).format(n);
}

export function fmtPct(n: number, digits = 2): string {
  if (!Number.isFinite(n)) return "-";
  return `${(n * 100).toFixed(digits)}%`;
}

export function fmtHf(hf: bigint): string {
  if (hf >= 2n ** 255n) return "∞";
  const n = Number(formatUnits(hf, 18));
  return n > 100 ? ">100" : n.toFixed(2);
}

export function hfNumber(hf: bigint): number {
  if (hf >= 2n ** 255n) return Infinity;
  return Number(formatUnits(hf, 18));
}

export function shortAddr(a?: string) {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "";
}

export { RAY, WAD };
