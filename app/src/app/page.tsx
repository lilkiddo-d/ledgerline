"use client";

import { useState } from "react";
import { forkConfigOnRemoteRpc, isDeployed } from "@/lib/config";
import { useMarkets, type Market } from "@/lib/hooks";
import { fmtAmount, fmtPct, fmtUsd, rayToApy, rayToPct, toNum, wadToNum } from "@/lib/format";
import { AssetIcon } from "@/components/AssetIcon";
import { ActionModal } from "@/components/ActionModal";
import type { Action } from "@/lib/risk";

export default function MarketsPage() {
  const { markets, marketOpen, isLoading, error } = useMarkets();
  const [sel, setSel] = useState<{ m: Market; a: Action } | null>(null);

  const totalSupplied = markets.reduce((s, m) => s + toNum(m.totalSupply, m.decimals) * wadToNum(m.priceWad), 0);
  const totalBorrowed = markets.reduce((s, m) => s + toNum(m.totalDebt, m.decimals) * wadToNum(m.priceWad), 0);

  return (
    <>
      <h1>Markets</h1>
      <p className="sub">
        One shared stablecoin pool with isolated risk settings per tokenized stock. Supply to earn, borrow against
        collateral, or borrow a stock to go short.
      </p>

      {!isDeployed && (
        <div className="notice warn">
          No deployment configured. Run <span className="mono">script/Deploy.s.sol</span>; it writes{" "}
          <span className="mono">app/src/generated/deployment.json</span>.
        </div>
      )}
      {forkConfigOnRemoteRpc && (
        <div className="notice bad">
          This build uses a local-fork deployment config against a public RPC. Redeploy with the mainnet{" "}
          <span className="mono">deployment.json</span>.
        </div>
      )}
      {error && <div className="notice bad">Could not load markets: {error.message.split("\n")[0]}</div>}

      <div className="grid grid-3" style={{ marginBottom: 20 }}>
        <div className="card">
          <div className="stat-label">Total supplied</div>
          <div className="stat-value">{fmtUsd(totalSupplied, true)}</div>
        </div>
        <div className="card">
          <div className="stat-label">Total borrowed</div>
          <div className="stat-value">{fmtUsd(totalBorrowed, true)}</div>
        </div>
        <div className="card">
          <div className="stat-label">US equity market</div>
          <div className="stat-value">
            {marketOpen === undefined ? (
              "-"
            ) : marketOpen ? (
              <span className="badge good"><span className="dot" />Open</span>
            ) : (
              <span className="badge warn" title="Stock LTVs are lowered and new stock borrowing is capped"><span className="dot" />Closed: reduced LTVs</span>
            )}
          </div>
        </div>
      </div>

      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Asset</th>
              <th>Price</th>
              <th>Total supplied</th>
              <th>Supply APY</th>
              <th>Total borrowed</th>
              <th>Borrow APY</th>
              <th>Utilization</th>
              <th>LTV / LT</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {isLoading && (
              <tr><td colSpan={9} className="muted">Loading markets…</td></tr>
            )}
            {markets.map((m) => {
              const price = wadToNum(m.priceWad);
              const util = rayToPct(m.utilizationRay);
              return (
                <tr key={m.asset}>
                  <td>
                    <div className="asset">
                      <AssetIcon symbol={m.symbol} />
                      <div>
                        <div className="asset-name">{m.symbol}</div>
                        <div className="asset-kind">
                          {m.params.isStock ? "Tokenized stock" : "Stablecoin"}
                          {m.params.eModeCategory === 1 ? " · E-mode: US Tech" : ""}
                          {m.frozen ? " · frozen" : ""}
                        </div>
                      </div>
                    </div>
                  </td>
                  <td>{m.priceOk ? fmtUsd(price) : <span className="badge bad">stale</span>}</td>
                  <td>
                    {fmtAmount(toNum(m.totalSupply, m.decimals), 2)}
                    <div className="muted" style={{ fontSize: 12 }}>{fmtUsd(toNum(m.totalSupply, m.decimals) * price, true)}</div>
                  </td>
                  <td style={{ color: "var(--good)" }}>{fmtPct(rayToApy(m.supplyRateRay))}</td>
                  <td>
                    {fmtAmount(toNum(m.totalDebt, m.decimals), 2)}
                    <div className="muted" style={{ fontSize: 12 }}>{fmtUsd(toNum(m.totalDebt, m.decimals) * price, true)}</div>
                  </td>
                  <td>{fmtPct(rayToApy(m.borrowRateRay))}</td>
                  <td>
                    {util.toFixed(1)}%
                    <span className="util"><span style={{ width: `${Math.min(100, util)}%` }} /></span>
                  </td>
                  <td>
                    {fmtPct(m.params.ltvBps / 10_000, 0)} / {fmtPct(m.params.liqThresholdBps / 10_000, 0)}
                    {m.params.isStock && !marketOpen && (
                      <div className="muted" style={{ fontSize: 12 }}>closed: {fmtPct(m.params.closedLtvBps / 10_000, 0)}</div>
                    )}
                  </td>
                  <td>
                    <div className="btn-row">
                      <button className="btn small" onClick={() => setSel({ m, a: "supply" })}>Supply</button>
                      <button className="btn small" onClick={() => setSel({ m, a: "borrow" })} disabled={!m.params.borrowEnabled}>
                        {m.params.isStock ? "Short" : "Borrow"}
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {sel && (
        <ActionModal market={sel.m} markets={markets} marketOpen={!!marketOpen} initial={sel.a} onClose={() => setSel(null)} />
      )}
    </>
  );
}
