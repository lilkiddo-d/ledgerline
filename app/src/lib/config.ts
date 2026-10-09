import { defineChain, type Address } from "viem";
import { robinhoodChain } from "@config/chains";
import deploymentJson from "@/generated/deployment.json";

export type AssetInfo = {
  symbol: string;
  decimals: number;
  address: Address;
  receiptToken: Address;
  debtToken: Address;
  feed: Address;
  isStock: boolean;
  eModeCategory: number;
};

export type Deployment = {
  name: string;
  deployment?: string;
  chainId: number;
  deployedAtBlock?: number;
  contracts: Partial<Record<
    | "Pool"
    | "AssetConfig"
    | "PoolLens"
    | "MarketClock"
    | "OracleAdapter"
    | "ComplianceRegistry"
    | "Reserve"
    | "FeeCollector"
    | "ProjectTokenHooks"
    | "Timelock",
    Address
  >>;
  stablecoin?: Address;
  assets: AssetInfo[];
};

export const deployment = deploymentJson as unknown as Deployment;
export const isDeployed = Boolean(deployment.contracts.Pool);

const rpcOverride = process.env.NEXT_PUBLIC_RPC_URL?.trim();
export const rpcUrl = rpcOverride || robinhoodChain.rpcUrls.default.http[0];
export const isLocalRpc = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?/.test(rpcUrl);

/** A local-fork deployment config pointed at a non-local RPC would show wrong addresses. */
export const forkConfigOnRemoteRpc = !isLocalRpc && /fork/i.test(deployment.deployment ?? "");

export const chain = defineChain({
  id: robinhoodChain.id,
  name: robinhoodChain.name,
  nativeCurrency: robinhoodChain.nativeCurrency,
  rpcUrls: { default: { http: [rpcUrl] } },
  blockExplorers: robinhoodChain.blockExplorers,
  contracts: { multicall3: { address: robinhoodChain.contracts.multicall3.address } },
});

/** $LEDG address; empty string hides every token feature. */
export const projectToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN?.trim() || "") as Address | "";
export const tokenFeaturesEnabled = /^0x[0-9a-fA-F]{40}$/.test(projectToken);

export const walletConnectProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID?.trim() || "";

/** Dev-only impersonated account for an anvil fork. Ignored unless the RPC is localhost. */
const devAccount = process.env.NEXT_PUBLIC_DEV_MOCK_ACCOUNT?.trim() || "";
export const devMockAccount = isLocalRpc && /^0x[0-9a-fA-F]{40}$/.test(devAccount) ? (devAccount as Address) : undefined;

export function assetBySymbol(symbol: string) {
  return deployment.assets.find((a) => a.symbol === symbol);
}

export function assetByAddress(address: string) {
  return deployment.assets.find((a) => a.address.toLowerCase() === address.toLowerCase());
}

export const explorerAddress = (a: string) => `${robinhoodChain.blockExplorers.default.url}/address/${a}`;
export const explorerTx = (h: string) => `${robinhoodChain.blockExplorers.default.url}/tx/${h}`;
