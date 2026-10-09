"use client";

import { useEffect, useState } from "react";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { erc20Abi, parseUnits, type Abi, type Address } from "viem";
import { poolAbi, poolLensAbi } from "@/generated/abis";
import { deployment, isDeployed } from "@/lib/config";
import { useMarkets, useUserPositions, useWallet } from "@/lib/hooks";
import { fmtAmount, fmtHf, fmtUsd, hfNumber, MAX_UINT, shortAddr, toNum, wadToNum } from "@/lib/format";
import { hfColor } from "@/lib/risk";
import { useTxRunner } from "@/lib/useTx";

const pool = deployment.contracts.Pool as Address;
const lens = deployment.contracts.PoolLens as Address;
const CHUNK = 200_000n;
const MAX_CHUNKS = 50;

/** Collects every address that ever borrowed by scanning Borrow events in bounded chunks. */
function useBorrowers() {
  const client = usePublicClient();
  const [borrowers, setBorrowers] = useState<Address[]>([]);
  const [status, setStatus] = useState("idle");
  const [tick, setTick] = useState(0);

  useEffect(() => {
    if (!client || !isDeployed) return;
    let cancelled = false;
    (async () => {
      setStatus("scanning");
      try {
        const latest = await client.getBlockNumber();
        const start = BigInt(deployment.deployedAtBlock ?? 0);
        const from = latest - start > CHUNK * BigInt(MAX_CHUNKS) ? latest - CHUNK * BigInt(MAX_CHUNKS) : start;
        const seen = new Set<string>();
        for (let b = from; b <= latest; b += CHUNK) {
          const to = b + CHUNK - 1n > latest ? latest : b + CHUNK - 1n;
          const logs = await client.getContractEvents({ address: pool, abi: poolAbi, eventName: "Borrow", fromBlock: b, toBlock: to });
          for (const l of logs) {
            const who = (l.args as { borrower?: Address }).borrower;
            if (who) seen.add(who);
          }
          if (cancelled) return;
        }
        setBorrowers([...seen] as Address[]);
        setStatus("done");
      } catch (e) {
        setStatus(`error: ${(e as Error).message.split("\n")[0]}`);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [client, tick]);

  return { borrowers, status, rescan: () => setTick((t) => t + 1) };
}

function LiquidatePanel({ user, onDone }: { user: Address; onDone: () => void }) {
  const { address } = useAccount();
  const { markets } = useMarkets();
  const { positions } = useUserPositions(user);
  const { byAsset } = useWallet();
  const tx = useTxRunner();
  const colls = positions.filter((p) => p.collateral && p.supplied > 0n);
  const debts = positions.filter((p) => p.borrowed > 0n);
  const [coll, setColl] = useState<string>("");
  const [debt, setDebt] = useState<string>("");
  const [amount, setAmount] = useState("");
  const [receipt, setReceipt] = useState(false);

  const c = coll || colls[0]?.asset || "";
  const dAsset = debt || debts[0]?.asset || "";
  const dm = markets.find((m) => m.asset.toLowerCase() === dAsset.toLowerCase());
  const dPos = debts.find((p) => p.asset.toLowerCase() === dAsset.toLowerCase());

  async function go() {
    if (!dm || !address) return;
    const raw = amount ? parseUnits(amount, dm.decimals) : (dPos?.borrowed ?? 0n);
    const wallet = byAsset.get(dm.asset.toLowerCase());
    const steps: { label: string; address: Address; abi: Abi; functionName: string; args: readonly unknown[] }[] = [];
    if (!wallet || wallet.allowance < raw) {
      steps.push({ label: `Approve ${dm.symbol}`, address: dm.asset as Address, abi: erc20Abi as Abi, functionName: "approve", args: [pool, raw] });
    }
    steps.push({ label: "Liquidate", address: pool, abi: poolAbi as Abi, functionName: "liquidate", args: [c, dAsset, user, amount ? raw : MAX_UINT, receipt] });
    if (await tx.run(steps)) onDone();
  }

  const sym = (a: string) => markets.find((m) => m.asset.toLowerCase() === a.toLowerCase())?.symbol ?? shortAddr(a);
  return (
    <div className="card" style={{ marginTop: 12 }}>
      <h2>Liquidate {shortAddr(user)}</h2>
      <div className="grid grid-3">
        <label>
          <div className="stat-label">Seize collateral</div>
          <select value={c} onChange={(e) => setColl(e.target.value)}>
            {colls.map((p) => <option key={p.asset} value={p.asset}>{sym(p.asset)}</option>)}
          </select>
        </label>
        <label>
          <div className="stat-label">Repay debt</div>
          <select value={dAsset} onChange={(e) => setDebt(e.target.value)}>
            {debts.map((p) => <option key={p.asset} value={p.asset}>{sym(p.asset)}</option>)}
          </select>
        </label>
        <label>
          <div className="stat-label">Amount (empty = max allowed)</div>
          <div className="field" style={{ padding: "6px 10px" }}>
            <input value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} placeholder={dPos && dm ? fmtAmount(toNum(dPos.borrowed, dm.decimals)) : "0"} style={{ fontSize: 15 }} />
          </div>
        </label>
      </div>
      <label style={{ display: "flex", gap: 8, margin: "12px 0" }}>
        <input type="checkbox" checked={receipt} onChange={(e) => setReceipt(e.target.checked)} />
        Receive collateral as interest-bearing receipt tokens (works even when pool cash is low)
      </label>
      <button className="btn danger" disabled={!address || !c || !dAsset || tx.state.status === "pending"} onClick={go}>
        {tx.state.status === "pending" ? tx.state.message : "Liquidate"}
      </button>
      {!address && <div className="muted" style={{ marginTop: 8 }}>Connect a wallet to liquidate.</div>}
      {tx.state.status === "error" && <div className="error">{tx.state.message}</div>}
      {tx.state.status === "success" && <div className="ok">Liquidation confirmed.</div>}
    </div>
  );
}

export default function LiquidationsPage() {
  const { borrowers, status, rescan } = useBorrowers();
  const [target, setTarget] = useState<Address | null>(null);
  const hfs = useReadContract({
    address: lens,
    abi: poolLensAbi,
    functionName: "getHealthFactors",
    args: [borrowers],
    query: { enabled: isDeployed && borrowers.length > 0, refetchInterval: 15_000 },
  });

  const rows = borrowers
    .map((b, i) => ({ user: b, data: hfs.data?.[i] }))
    .filter((r) => r.data && r.data.debtUsd > 0n)
    .sort((a, b) => (a.data!.healthFactor < b.data!.healthFactor ? -1 : 1));

  return (
    <>
      <h1>Liquidations</h1>
      <p className="sub">
        Anyone can repay part of an unhealthy account&apos;s debt (health factor below 1) and receive its collateral at a
        discount. Up to 50% of a debt can be repaid per call, or 100% once the health factor is below 0.95.
      </p>
      <div style={{ display: "flex", gap: 12, alignItems: "center", marginBottom: 14 }}>
        <span className="muted">Scanned {borrowers.length} borrowers · {status}</span>
        <button className="btn small" onClick={rescan}>Rescan</button>
      </div>
      <div className="table-wrap">
        <table>
          <thead>
            <tr><th>Account</th><th>Collateral</th><th>Debt</th><th>Health factor</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={6} className="muted">{status === "scanning" ? "Scanning borrow events…" : "No open borrow positions."}</td></tr>}
            {rows.map(({ user, data }) => {
              const hf = hfNumber(data!.healthFactor);
              return (
                <tr key={user}>
                  <td className="mono">{shortAddr(user)}</td>
                  <td>{fmtUsd(wadToNum(data!.collateralUsd))}</td>
                  <td>{fmtUsd(wadToNum(data!.debtUsd))}</td>
                  <td style={{ color: hfColor(hf) }}>{fmtHf(data!.healthFactor)}</td>
                  <td>{hf < 1 ? <span className="badge bad"><span className="dot" />Liquidatable</span> : hf < 1.1 ? <span className="badge warn"><span className="dot" />At risk</span> : <span className="badge good"><span className="dot" />Healthy</span>}</td>
                  <td><div className="btn-row"><button className="btn small" disabled={hf >= 1} onClick={() => setTarget(user)}>Liquidate</button></div></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {target && <LiquidatePanel user={target} onDone={() => { setTarget(null); hfs.refetch(); }} />}
      <p className="muted" style={{ fontSize: 13, marginTop: 16 }}>
        This page scans recent on-chain events directly from the RPC. For production-scale monitoring run an indexer and
        a liquidation bot; see docs/LIQUIDATIONS.md.
      </p>
    </>
  );
}
