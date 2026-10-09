"use client";

import { useState } from "react";
import { useAccount, useReadContracts } from "wagmi";
import { erc20Abi, parseUnits, type Abi, type Address } from "viem";
import { projectTokenHooksAbi } from "@/generated/abis";
import { deployment, projectToken, tokenFeaturesEnabled } from "@/lib/config";
import { fmtAmount, toNum } from "@/lib/format";
import { useTxRunner } from "@/lib/useTx";

const hooks = deployment.contracts.ProjectTokenHooks as Address | undefined;

export default function StakePage() {
  if (!tokenFeaturesEnabled || !hooks) {
    return (
      <>
        <h1>Staking</h1>
        <div className="notice">Token features are not live yet.</div>
      </>
    );
  }
  return <Stake hooks={hooks} token={projectToken as Address} />;
}

function Stake({ hooks, token }: { hooks: Address; token: Address }) {
  const { address } = useAccount();
  const tx = useTxRunner();
  const [amount, setAmount] = useState("");
  const user = address ?? "0x0000000000000000000000000000000000000000";
  const q = useReadContracts({
    contracts: [
      { address: hooks, abi: projectTokenHooksAbi, functionName: "isActive" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "staked", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "earned", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "borrowDiscountBps", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "pendingUnstake", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "unstakeReadyAt", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "totalStaked" },
      { address: token, abi: erc20Abi, functionName: "balanceOf", args: [user] },
      { address: token, abi: erc20Abi, functionName: "allowance", args: [user, hooks] },
      { address: token, abi: erc20Abi, functionName: "decimals" },
      { address: token, abi: erc20Abi, functionName: "symbol" },
    ],
    query: { refetchInterval: 15_000 },
  });
  const r = q.data?.map((x) => x.result);
  const active = r?.[0] as boolean | undefined;
  const dec = (r?.[9] as number | undefined) ?? 18;
  const sym = (r?.[10] as string | undefined) ?? "LEDG";
  const n = (i: number) => (r?.[i] as bigint | undefined) ?? 0n;
  const readyAt = Number(n(5));
  const stable = deployment.assets.find((a) => !a.isStock);

  if (active === false) {
    return (
      <>
        <h1>Staking</h1>
        <div className="notice warn">
          NEXT_PUBLIC_PROJECT_TOKEN is set, but the on-chain token has not been activated yet (setProjectToken via the
          Timelock).
        </div>
      </>
    );
  }

  let raw = 0n;
  try { raw = amount ? parseUnits(amount, dec) : 0n; } catch { raw = 0n; }

  const stake = () =>
    tx.run([
      ...(n(8) < raw ? [{ label: "Approve", address: token, abi: erc20Abi as Abi, functionName: "approve", args: [hooks, raw] as const }] : []),
      { label: "Stake", address: hooks, abi: projectTokenHooksAbi as Abi, functionName: "stake", args: [raw] },
    ]);
  const unstake = () => tx.run([{ label: "Request unstake", address: hooks, abi: projectTokenHooksAbi as Abi, functionName: "requestUnstake", args: [raw] }]);
  const withdraw = () => tx.run([{ label: "Withdraw", address: hooks, abi: projectTokenHooksAbi as Abi, functionName: "withdrawUnstaked", args: [] }]);
  const claim = () => tx.run([{ label: "Claim", address: hooks, abi: projectTokenHooksAbi as Abi, functionName: "claim", args: [] }]);

  return (
    <>
      <h1>Stake {sym}</h1>
      <p className="sub">
        Stakers earn a share of protocol reserve-factor revenue, paid in {stable?.symbol ?? "the stablecoin"}, and get a
        discount on the protocol&apos;s share of their borrow interest. Unstaking has a cooldown.
      </p>
      <div className="grid grid-4" style={{ marginBottom: 20 }}>
        <div className="card"><div className="stat-label">Your stake</div><div className="stat-value">{fmtAmount(toNum(n(1), dec))}</div></div>
        <div className="card"><div className="stat-label">Claimable</div><div className="stat-value">{fmtAmount(toNum(n(2), stable?.decimals ?? 6))} {stable?.symbol}</div></div>
        <div className="card"><div className="stat-label">Borrow discount</div><div className="stat-value">{Number(n(3)) / 100}%</div></div>
        <div className="card"><div className="stat-label">Total staked</div><div className="stat-value">{fmtAmount(toNum(n(6), dec), 0)}</div></div>
      </div>
      <div className="card" style={{ maxWidth: 480 }}>
        <div className="field"><input value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} placeholder="0.0" aria-label="Amount" /><span className="muted">{sym}</span></div>
        <div className="kv"><span>Wallet</span><b>{fmtAmount(toNum(n(7), dec))} {sym}</b></div>
        <div className="kv"><span>Pending unstake</span><b>{fmtAmount(toNum(n(4), dec))}{readyAt > 0 ? ` · ready ${new Date(readyAt * 1000).toLocaleString()}` : ""}</b></div>
        <div className="btn-row" style={{ justifyContent: "flex-start", marginTop: 12 }}>
          <button className="btn primary" disabled={!address || raw === 0n} onClick={stake}>Stake</button>
          <button className="btn" disabled={!address || raw === 0n || raw > n(1)} onClick={unstake}>Request unstake</button>
          <button className="btn" disabled={!address || n(4) === 0n || Date.now() / 1000 < readyAt} onClick={withdraw}>Withdraw</button>
          <button className="btn" disabled={!address || n(2) === 0n} onClick={claim}>Claim</button>
        </div>
        {tx.state.status === "pending" && <div className="muted" style={{ marginTop: 8 }}>{tx.state.message}</div>}
        {tx.state.status === "error" && <div className="error">{tx.state.message}</div>}
        {tx.state.status === "success" && <div className="ok">Confirmed.</div>}
      </div>
    </>
  );
}
