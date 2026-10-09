"use client";

import { useState } from "react";
import { usePublicClient, useWriteContract } from "wagmi";
import { BaseError, ContractFunctionRevertedError, type Abi } from "viem";
import { useQueryClient } from "@tanstack/react-query";

export type TxState = { status: "idle" | "pending" | "success" | "error"; message?: string; hash?: string };

/** Human-readable error from a viem/wagmi failure, surfacing the custom error name when available. */
export function errorMessage(e: unknown): string {
  if (e instanceof BaseError) {
    const revert = e.walk((err) => err instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      return revert.data?.errorName ? `Reverted: ${revert.data.errorName}` : revert.shortMessage;
    }
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

/** Sends a sequence of contract writes, waiting for each receipt, then refreshes all queries. */
export function useTxRunner() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const qc = useQueryClient();
  const [state, setState] = useState<TxState>({ status: "idle" });

  async function run(
    steps: { label: string; address: `0x${string}`; abi: Abi; functionName: string; args: readonly unknown[] }[],
  ) {
    try {
      let hash: `0x${string}` | undefined;
      for (const s of steps) {
        setState({ status: "pending", message: `${s.label}: confirm in wallet…` });
        hash = await writeContractAsync({ address: s.address, abi: s.abi, functionName: s.functionName, args: s.args } as never);
        setState({ status: "pending", message: `${s.label}: waiting for confirmation…`, hash });
        const receipt = await client!.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error(`${s.label} reverted`);
      }
      setState({ status: "success", message: "Confirmed", hash });
      await qc.invalidateQueries();
      return true;
    } catch (e) {
      setState({ status: "error", message: errorMessage(e) });
      return false;
    }
  }

  return { state, run, reset: () => setState({ status: "idle" }) };
}
