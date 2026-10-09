"use client";

import { useMemo, useState } from "react";
import { useAccount } from "wagmi";
import { erc20Abi, parseUnits, type Abi, type Address } from "viem";
import { poolAbi } from "@/generated/abis";
import { deployment } from "@/lib/config";
import { fmtAmount, fmtPct, fmtUsd, MAX_UINT, rayToApy, toNum, wadToNum } from "@/lib/format";
import { useEModeCategory, useUserPositions, useWallet, type Market } from "@/lib/hooks";
import { projectedHf, totals, hfColor, type Action } from "@/lib/risk";
import { useTxRunner } from "@/lib/useTx";
import { AssetIcon } from "./AssetIcon";

const pool = deployment.contracts.Pool as Address;

export function ActionModal({
  market,
  markets,
  marketOpen,
  initial,
  onClose,
}: {
  market: Market;
  markets: readonly Market[];
  marketOpen: boolean;
  initial: Action;
  onClose: () => void;
}) {
  const { address } = useAccount();
  const [action, setAction] = useState<Action>(initial);
  const [input, setInput] = useState("");
  const { positions, eMode } = useUserPositions(address);
  const em = useEModeCategory(eMode).data;
  const { byAsset } = useWallet();
  const tx = useTxRunner();

  const dec = market.decimals;
  const price = wadToNum(market.priceWad);
  const wallet = byAsset.get(market.asset.toLowerCase()) ?? { balance: 0n, allowance: 0n };
  const pos = positions.find((p) => p.asset.toLowerCase() === market.asset.toLowerCase());
  const supplied = pos?.supplied ?? 0n;
  const borrowed = pos?.borrowed ?? 0n;
  const emode = em ? { ltvBps: em.ltvBps, liqThresholdBps: em.liqThresholdBps } : undefined;
  const mk = markets as unknown as Parameters<typeof totals>[0];
  const ps = positions as unknown as Parameters<typeof totals>[1];

  const maxRaw = useMemo((): bigint => {
    if (action === "supply") return wallet.balance;
    if (action === "withdraw") return supplied < market.cash ? supplied : market.cash;
    if (action === "repay") return borrowed < wallet.balance ? borrowed : wallet.balance;
    // borrow: remaining LTV headroom (99%), capped by pool cash
    const t = totals(mk, ps, eMode, emode, marketOpen);
    const headroomUsd = Math.max(0, t.power - t.debt) * 0.99;
    if (price <= 0) return 0n;
    const qty = headroomUsd / price;
    const raw = parseUnits(qty.toFixed(Math.min(dec, 8)), dec);
    return raw < market.cash ? raw : market.cash;
  }, [action, wallet.balance, supplied, borrowed, market.cash, mk, ps, eMode, emode, marketOpen, price, dec]);

  let amountRaw = 0n;
  let parseError = "";
  try {
    amountRaw = input ? parseUnits(input, dec) : 0n;
  } catch {
    parseError = "Invalid amount";
  }
  const amount = toNum(amountRaw, dec);
  const hfAfter = projectedHf(mk, ps, eMode, emode, marketOpen, action, market.asset, amount);
  const t = totals(mk, ps, eMode, emode, marketOpen);
  const hfNow = t.debt === 0 ? Infinity : t.weighted / t.debt;

  const borrowBlocked = action === "borrow" && (!market.params.borrowEnabled || (eMode !== 0 && market.params.eModeCategory !== eMode));
  const supplyBlocked = action === "supply" && market.frozen;
  const tooMuch = amountRaw > maxRaw && !(action === "repay" && amountRaw >= borrowed && wallet.balance >= borrowed);
  const unsafe = (action === "borrow" || action === "withdraw") && Number.isFinite(hfAfter) && hfAfter < 1.0;

  async function submit() {
    if (!address || amountRaw === 0n) return;
    const isMaxWithdraw = action === "withdraw" && amountRaw >= supplied;
    const isFullRepay = action === "repay" && amountRaw >= borrowed;
    const steps: { label: string; address: Address; abi: Abi; functionName: string; args: readonly unknown[] }[] = [];
    const needsApproval = action === "supply" || action === "repay";
    // Full repay approves a 0.5% buffer for interest accruing until the tx lands.
    const approveAmount = isFullRepay ? borrowed + borrowed / 200n + 1n : amountRaw;
    if (needsApproval && wallet.allowance < approveAmount) {
      steps.push({ label: `Approve ${market.symbol}`, address: market.asset as Address, abi: erc20Abi as Abi, functionName: "approve", args: [pool, approveAmount] });
    }
    if (action === "supply") steps.push({ label: "Supply", address: pool, abi: poolAbi as Abi, functionName: "supply", args: [market.asset, amountRaw, address] });
    if (action === "withdraw") steps.push({ label: "Withdraw", address: pool, abi: poolAbi as Abi, functionName: "withdraw", args: [market.asset, isMaxWithdraw ? MAX_UINT : amountRaw, address] });
    if (action === "borrow") steps.push({ label: "Borrow", address: pool, abi: poolAbi as Abi, functionName: "borrow", args: [market.asset, amountRaw] });
    if (action === "repay") steps.push({ label: "Repay", address: pool, abi: poolAbi as Abi, functionName: "repay", args: [market.asset, isFullRepay ? MAX_UINT : amountRaw, address] });
    const ok = await tx.run(steps);
    if (ok) setInput("");
  }

  const apy = action === "supply" || action === "withdraw" ? rayToApy(market.supplyRateRay) : rayToApy(market.borrowRateRay);

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <div className="modal-head">
          <div className="asset">
            <AssetIcon symbol={market.symbol} />
            <div>
              <div className="asset-name">{market.symbol}</div>
              <div className="asset-kind">{fmtUsd(price)}</div>
            </div>
          </div>
          <button className="close" onClick={onClose} aria-label="Close">×</button>
        </div>

        <div className="tabs">
          {(["supply", "withdraw", "borrow", "repay"] as Action[]).map((a) => (
            <button key={a} className={a === action ? "active" : ""} onClick={() => { setAction(a); setInput(""); tx.reset(); }}>
              {a[0].toUpperCase() + a.slice(1)}
            </button>
          ))}
        </div>

        {market.params.isStock && action === "borrow" && (
          <div className="notice warn" style={{ marginBottom: 12 }}>
            Borrowing a stock token is a short position: if the price rises, your debt grows in value.
          </div>
        )}

        <div className="field">
          <input inputMode="decimal" placeholder="0.0" value={input} onChange={(e) => setInput(e.target.value.replace(/[^0-9.]/g, ""))} aria-label="Amount" />
          <button className="btn small" onClick={() => setInput(toNum(maxRaw, dec).toString())}>Max</button>
        </div>
        <div className="kv"><span>≈ value</span><b>{fmtUsd(amount * price)}</b></div>

        <div style={{ margin: "10px 0" }}>
          <div className="kv"><span>Wallet</span><b>{fmtAmount(toNum(wallet.balance, dec))} {market.symbol}</b></div>
          <div className="kv"><span>Supplied</span><b>{fmtAmount(toNum(supplied, dec))}</b></div>
          <div className="kv"><span>Borrowed</span><b>{fmtAmount(toNum(borrowed, dec))}</b></div>
          <div className="kv"><span>{action === "supply" || action === "withdraw" ? "Supply APY" : "Borrow APY"}</span><b>{fmtPct(apy)}</b></div>
          <div className="kv">
            <span>Health factor</span>
            <b>
              <span style={{ color: hfColor(hfNow) }}>{Number.isFinite(hfNow) ? hfNow.toFixed(2) : "∞"}</span>
              {" → "}
              <span style={{ color: hfColor(hfAfter) }}>{Number.isFinite(hfAfter) ? hfAfter.toFixed(2) : "∞"}</span>
            </b>
          </div>
          {!marketOpen && market.params.isStock && (
            <div className="kv"><span>Market closed</span><b>LTV capped at {fmtPct(market.params.closedLtvBps / 10_000, 0)}</b></div>
          )}
        </div>

        {!address ? (
          <div className="notice">Connect a wallet to continue.</div>
        ) : (
          <button
            className="btn primary"
            style={{ width: "100%" }}
            disabled={!!parseError || amountRaw === 0n || tooMuch || unsafe || borrowBlocked || supplyBlocked || tx.state.status === "pending"}
            onClick={submit}
          >
            {tx.state.status === "pending" ? "Working…" : action[0].toUpperCase() + action.slice(1)}
          </button>
        )}
        {parseError && <div className="error">{parseError}</div>}
        {tooMuch && <div className="error">Amount exceeds the available maximum.</div>}
        {unsafe && <div className="error">This would put the account below a health factor of 1.</div>}
        {borrowBlocked && <div className="error">Borrowing disabled for this asset{eMode !== 0 ? " in your e-mode category" : ""}.</div>}
        {supplyBlocked && <div className="error">This market is frozen for new supply.</div>}
        {tx.state.status === "pending" && <div className="muted" style={{ marginTop: 8 }}>{tx.state.message}</div>}
        {tx.state.status === "error" && <div className="error">{tx.state.message}</div>}
        {tx.state.status === "success" && <div className="ok">Transaction confirmed.</div>}
      </div>
    </div>
  );
}
