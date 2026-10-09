#!/usr/bin/env bash
# Fallback for contract verification. Blockscout on Robinhood Chain sits behind a Cloudflare
# challenge that can block `forge --verify`. This writes a Solidity standard-JSON input per contract
# to deployments/verify/, which you upload in the Blockscout UI:
#   Contract page -> "Verify & Publish" -> "Solidity (Standard JSON input)", compiler v0.8.28.
# Blockscout reads constructor arguments from the creation transaction automatically.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORGE="${FORGE:-forge}"
OUT="$ROOT/deployments/verify"
mkdir -p "$OUT"
cd "$ROOT/contracts"
for c in \
  src/core/Pool.sol:Pool src/core/AssetConfig.sol:AssetConfig src/core/LiquidationLogic.sol:LiquidationLogic \
  src/core/FlashLoan.sol:FlashLoan src/core/InterestRateModel.sol:InterestRateModel \
  src/core/ReceiptToken.sol:ReceiptToken src/core/DebtToken.sol:DebtToken \
  src/risk/MarketClock.sol:MarketClock src/risk/OracleAdapter.sol:OracleAdapter \
  src/treasury/Reserve.sol:Reserve src/treasury/FeeCollector.sol:FeeCollector \
  src/token/ProjectTokenHooks.sol:ProjectTokenHooks src/governance/Timelock.sol:Timelock \
  src/compliance/ComplianceRegistry.sol:ComplianceRegistry src/periphery/PoolLens.sol:PoolLens; do
  name="${c##*:}"
  "$FORGE" verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000000 "$c" > "$OUT/$name.json"
  echo "wrote deployments/verify/$name.json"
done
echo "Compiler: v0.8.28, optimizer on (200 runs), EVM version cancun. Addresses: deployments/4663.json"
