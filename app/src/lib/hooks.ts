"use client";

import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { erc20Abi, type Address } from "viem";
import { poolLensAbi, assetConfigAbi } from "@/generated/abis";
import { deployment, isDeployed } from "./config";

const lens = deployment.contracts.PoolLens as Address | undefined;
const pool = deployment.contracts.Pool as Address | undefined;

export function useMarkets() {
  const q = useReadContract({
    address: lens,
    abi: poolLensAbi,
    functionName: "getMarkets",
    query: { enabled: isDeployed && !!lens, refetchInterval: 15_000 },
  });
  return { markets: q.data?.[0] ?? [], marketOpen: q.data?.[1], ...q };
}

export type Market = ReturnType<typeof useMarkets>["markets"][number];

export function useUserPositions(user?: Address) {
  const q = useReadContract({
    address: lens,
    abi: poolLensAbi,
    functionName: "getUserPositions",
    args: user ? [user] : undefined,
    query: { enabled: isDeployed && !!lens && !!user, refetchInterval: 15_000 },
  });
  return {
    positions: q.data?.[0] ?? [],
    account: q.data?.[1],
    eMode: q.data?.[2] ?? 0,
    ...q,
  };
}

export function useEModeCategory(id: number) {
  return useReadContract({
    address: deployment.contracts.AssetConfig as Address | undefined,
    abi: assetConfigAbi,
    functionName: "getEModeCategory",
    args: [id],
    query: { enabled: isDeployed && id > 0 },
  });
}

/** Wallet balances and Pool allowances for every listed asset. */
export function useWallet() {
  const { address } = useAccount();
  const contracts = deployment.assets.flatMap((a) => [
    { address: a.address, abi: erc20Abi, functionName: "balanceOf", args: [address!] } as const,
    { address: a.address, abi: erc20Abi, functionName: "allowance", args: [address!, pool!] } as const,
  ]);
  const q = useReadContracts({
    contracts,
    query: { enabled: isDeployed && !!address && !!pool, refetchInterval: 15_000 },
  });
  const byAsset = new Map<string, { balance: bigint; allowance: bigint }>();
  deployment.assets.forEach((a, i) => {
    const bal = q.data?.[i * 2]?.result as bigint | undefined;
    const alw = q.data?.[i * 2 + 1]?.result as bigint | undefined;
    byAsset.set(a.address.toLowerCase(), { balance: bal ?? 0n, allowance: alw ?? 0n });
  });
  return { byAsset, ...q };
}
