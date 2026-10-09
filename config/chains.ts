/**
 * Robinhood Chain network + official asset addresses used by Ledgerline.
 *
 * Every value below was taken from an official source (links inline) and verified on-chain
 * on 2026-10-08 (code present, symbol/decimals/description match). Nothing here is guessed.
 * Keep in sync with contracts/script/RobinhoodChain.sol.
 *
 * Sources
 *  - Network (chain id, RPC, explorer):    https://docs.robinhood.com/chain/connecting
 *  - Contract verification (Blockscout):   https://docs.robinhood.com/chain/deploy-smart-contracts
 *  - Stock tokens + stablecoins:           https://docs.robinhood.com/chain/contracts
 *      data feed behind that table:        https://api.robinhood.com/rhj/assets
 *  - Stock token standard (ERC-8056 UI):   https://docs.robinhood.com/chain/stock-tokens
 *  - Oracles (Chainlink only):             https://docs.robinhood.com/chain/oracles-and-price-feeds
 *      feed addresses:                     https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *      equity feed semantics (24/5):       https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood
 *
 * Known gaps (documented in DECISIONS.md / THREAT_MODEL.md):
 *  - No USDC token is deployed on Robinhood Chain (Circle lists none). USDG is the stablecoin market.
 *  - No Chainlink L2 sequencer-uptime feed exists for this chain. OracleAdapter supports one if added.
 *  - Only one oracle network (Chainlink). OracleAdapter accepts a secondary source once one exists.
 *  - Multicall3 (0xcA11...CA11) has code on-chain but is not listed in official docs.
 *  - No CREATE2 factory is documented (Arachnid's deployer has no code); deploys use plain CREATE.
 */

export type Address = `0x${string}`;

export const robinhoodChain = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.mainnet.chain.robinhood.com"] },
    // Alchemy also serves this chain: https://robinhood-mainnet.g.alchemy.com/v2/<key>
  },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" },
  },
  // Verification: forge --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
  verifierUrl: "https://robinhoodchain.blockscout.com/api/",
  contracts: {
    // On-chain verified (aggregate3 present, getChainId() == 4663) but not in official docs.
    multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" as Address },
  },
} as const;

export const robinhoodTestnet = {
  id: 46630,
  name: "Robinhood Chain Testnet",
  rpcUrl: "https://rpc.testnet.chain.robinhood.com",
  explorer: "https://explorer.testnet.chain.robinhood.com",
} as const;

/** USD-pegged stablecoin market. Global Dollar (USDG), 6 decimals. */
export const STABLECOIN = {
  symbol: "USDG",
  address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" as Address,
  decimals: 6,
  feed: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2" as Address, // Chainlink USDG/USD
} as const;

/** Tokenized stocks/ETFs listed at launch: 18 decimals, Chainlink 24/5 feeds (8 decimals). */
export const STOCKS = [
  { symbol: "AAPL", address: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0", tier: 1 },
  { symbol: "MSFT", address: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E", tier: 1 },
  { symbol: "NVDA", address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15", tier: 1 },
  { symbol: "GOOGL", address: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", feed: "0xF6f373a037c30F0e5010d854385cA89185AE638b", tier: 1 },
  { symbol: "META", address: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", feed: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1", tier: 1 },
  { symbol: "AMZN", address: "0x12f190a9F9d7D37a250758b26824B97CE941bF54", feed: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C", tier: 1 },
  { symbol: "TSLA", address: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", feed: "0x4A1166a659A55625345e9515b32adECea5547C38", tier: 2 },
  { symbol: "SPY", address: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", feed: "0x319724394D3A0e3669269846abE664Cd621f9f6A", tier: 0 },
  { symbol: "QQQ", address: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", feed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae", tier: 0 },
] as const satisfies ReadonlyArray<{ symbol: string; address: Address; feed: Address; tier: 0 | 1 | 2 }>;

/** Other official addresses we reference but do not list as markets. */
export const OTHER = {
  weth: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73" as Address, // docs.robinhood.com/chain/contracts
  ethUsdFeed: "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9" as Address, // Chainlink ETH/USD
  usdcUsdFeed: "0x9e6f4605992a899eE2999999F3Ec80C41F452546" as Address, // Chainlink USDC/USD (no USDC token on chain)
} as const;
