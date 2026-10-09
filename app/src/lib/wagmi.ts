import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  coinbaseWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import { mock } from "wagmi/connectors";
import { chain, devMockAccount, walletConnectProjectId } from "./config";

const wallets = walletConnectProjectId
  ? [injectedWallet, metaMaskWallet, rabbyWallet, coinbaseWallet, walletConnectWallet]
  : [injectedWallet, metaMaskWallet, rabbyWallet, coinbaseWallet];

const rkConnectors = connectorsForWallets([{ groupName: "Wallets", wallets }], {
  appName: "Ledgerline",
  // RainbowKit requires a string; WalletConnect itself is only offered when a real id is configured.
  projectId: walletConnectProjectId || "ledgerline-no-walletconnect",
});

export const DEV_CONNECTOR_ID = "ledgerline-dev";

const devConnectors = devMockAccount
  ? [
      mock({ accounts: [devMockAccount], features: { reconnect: true } }),
    ]
  : [];

export const wagmiConfig = createConfig({
  chains: [chain],
  connectors: [...rkConnectors, ...devConnectors],
  transports: { [chain.id]: http(chain.rpcUrls.default.http[0], { batch: true, retryCount: 3 }) },
  ssr: true,
});
