"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import type { Abi, Address } from "viem";
import { poolAbi } from "@/generated/abis";
import { deployment } from "@/lib/config";
import { useEModeCategory, useMarkets, useUserPositions, type Market } from "@/lib/hooks";
import { fmtAmount, fmtUsd, hfNumber, toNum, wadToNum } from "@/lib/format";
import { liquidationPrice, totals, type Action } from "@/lib/risk";
import { useTxRunner } from "@/lib/useTx";
import { HealthGauge } from "@/components/HealthGauge";
import { AssetIcon } from "@/components/AssetIcon";
import { ActionModal } from "@/components/ActionModal";

const pool = deployment.contracts.Pool as Address;

export default function AccountPage() {
  const { address } = useAccount();
  const { markets, marketOpen } = useMarkets();
  const { positions, account, eMode } = useUserPositions(address);
  const em = useEModeCategory(1).data; // the only category configured at launch
  const tx = useTxRunner();
  const [sel, setSel] = useState<{ m: Market; a: Action } | null>(null);

  if (!address) {
    return (
      <>
        <h1>Account</h1>
        <div className="notice">Connect a wallet to see your positions.</div>
      </>
    );
  }

  const open = !!marketOpen;
  const emode = eMode !== 0 && em ? { ltvBps: em.ltvBps, liqThresholdBps: em.liqThresholdBps } : undefined;
  const mk = markets as unknown as Parameters<typeof totals>[0];
  const ps = positions as unknown as Parameters<typeof totals>[1];
  const hf = account ? hfNumber(account.healthFactor) : Infinity;
  const active = positions.filter((p) => p.supplied > 0n || p.borrowed > 0n);
  const marketOf = (a: string) => markets.find((m) => m.asset.toLowerCase() === a.toLowerCase());

  const toggleCollateral = (asset: string, enabled: boolean) =>
    tx.run([{ label: enabled ? "Enable collateral" : "Disable collateral", address: pool, abi: poolAbi as Abi, functionName: "setUseAsCollateral", args: [asset, enabled] }]);
  const setEMode = (id: number) =>
    tx.run([{ label: "Set e-mode", address: pool, abi: poolAbi as Abi, functionName: "setEMode", args: [id] }]);

  return (
    <>
      <h1>Account</h1>
      <p className="sub mono">{address}</p>

      <div className="grid grid-2" style={{ marginBottom: 20 }}>
        <div className="card" style={{ display: "flex", alignItems: "center", gap: 20, flexWrap: "wrap" }}>
          <HealthGauge hf={hf} />
          <div>
            <div className="stat-label">Health factor</div>
            <p className="muted" style={{ maxWidth: 260, fontSize: 14 }}>
              Below 1.00 your position can be liquidated. Below 0.95, liquidators may repay all of your debt at once.
            </p>
            {hf < 1 && <span className="badge bad"><span className="dot" />Liquidatable</span>}
          </div>
        </div>
        <div className="card">
          <div className="grid grid-2">
            <div><div className="stat-label">Collateral</div><div className="stat-value">{fmtUsd(account ? wadToNum(account.collateralUsd) : 0)}</div></div>
            <div><div className="stat-label">Debt</div><div className="stat-value">{fmtUsd(account ? wadToNum(account.debtUsd) : 0)}</div></div>
            <div><div className="stat-label">Borrow power</div><div className="stat-value">{fmtUsd(account ? wadToNum(account.borrowPowerUsd) : 0)}</div></div>
            <div>
              <div className="stat-label">E-mode</div>
              <div style={{ marginTop: 6 }}>
                <select value={eMode} onChange={(e) => setEMode(Number(e.target.value))} disabled={tx.state.status === "pending"} aria-label="E-mode category">
                  <option value={0}>Off</option>
                  <option value={1}>US Tech{em ? ` (LTV ${em.ltvBps / 100}%)` : ""}</option>
                </select>
              </div>
            </div>
          </div>
          {!open && (
            <p className="muted" style={{ fontSize: 13, marginBottom: 0 }}>
              US equity market is closed: stock collateral counts at reduced LTV until the next session.
            </p>
          )}
        </div>
      </div>

      {tx.state.status === "error" && <div className="notice bad">{tx.state.message}</div>}

      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Asset</th>
              <th>Supplied</th>
              <th>Collateral</th>
              <th>Borrowed</th>
              <th>Price</th>
              <th title="Price at which this position alone would bring your health factor to 1">Liquidation price</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {active.length === 0 && (
              <tr><td colSpan={7} className="muted">No positions yet. Supply an asset from the Markets page.</td></tr>
            )}
            {active.map((p) => {
              const m = marketOf(p.asset);
              if (!m) return null;
              const price = wadToNum(m.priceWad);
              const liq = liquidationPrice(mk, ps, eMode, emode, open, p.asset);
              const direction = p.borrowed > 0n && !p.collateral ? "↑" : "↓";
              return (
                <tr key={p.asset}>
                  <td><div className="asset"><AssetIcon symbol={m.symbol} /><span className="asset-name">{m.symbol}</span></div></td>
                  <td>{fmtAmount(toNum(p.supplied, m.decimals))}<div className="muted" style={{ fontSize: 12 }}>{fmtUsd(toNum(p.supplied, m.decimals) * price)}</div></td>
                  <td>
                    {p.supplied > 0n ? (
                      <label style={{ cursor: "pointer" }}>
                        <input type="checkbox" checked={p.collateral} disabled={tx.state.status === "pending" || !m.params.collateralEnabled} onChange={(e) => toggleCollateral(p.asset, e.target.checked)} />
                      </label>
                    ) : "-"}
                  </td>
                  <td>{fmtAmount(toNum(p.borrowed, m.decimals))}<div className="muted" style={{ fontSize: 12 }}>{fmtUsd(toNum(p.borrowed, m.decimals) * price)}</div></td>
                  <td>{fmtUsd(price)}</td>
                  <td>{liq ? <span title={direction === "↑" ? "liquidated if price rises above" : "liquidated if price falls below"}>{direction} {fmtUsd(liq)}</span> : "-"}</td>
                  <td>
                    <div className="btn-row">
                      {p.supplied > 0n && <button className="btn small" onClick={() => setSel({ m, a: "withdraw" })}>Withdraw</button>}
                      {p.borrowed > 0n && <button className="btn small" onClick={() => setSel({ m, a: "repay" })}>Repay</button>}
                      <button className="btn small" onClick={() => setSel({ m, a: "supply" })}>Supply</button>
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {sel && <ActionModal market={sel.m} markets={markets} marketOpen={open} initial={sel.a} onClose={() => setSel(null)} />}
    </>
  );
}
