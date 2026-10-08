// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title RobinhoodChain
/// @notice Official Robinhood Chain mainnet addresses. Mirrors config/chains.ts (keep in sync).
/// Sources (retrieved 2026-10-08):
///  - Network:      https://docs.robinhood.com/chain/connecting
///  - Tokens:       https://docs.robinhood.com/chain/contracts  (data: https://api.robinhood.com/rhj/assets)
///  - Stablecoins:  https://docs.robinhood.com/chain/contracts  (USDG; no USDC token is deployed)
///  - Price feeds:  https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
///                  (data: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json)
/// Every token/feed below was checked on-chain (symbol/decimals/description) before inclusion, and
/// Deploy.s.sol re-checks code presence and live prices before broadcasting.
library RobinhoodChain {
    uint256 internal constant CHAIN_ID = 4663;

    // Stablecoin: Global Dollar (USDG), 6 decimals
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    // Stock tokens (ERC-20, 18 decimals, ERC-8056 scaled UI amount) and Chainlink 24/5 feeds (8 decimals)
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address internal constant MSFT_FEED = 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address internal constant GOOGL_FEED = 0xF6f373a037c30F0e5010d854385cA89185AE638b;
    address internal constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address internal constant META_FEED = 0x7C38C00C30BEe9378381E7B6135d7283356D71b1;
    address internal constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address internal constant AMZN_FEED = 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant SPY_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address internal constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address internal constant QQQ_FEED = 0x80901d846d5D7B030F26B480776EE3b29374C2ae;
}
