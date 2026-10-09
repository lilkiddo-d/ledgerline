#!/usr/bin/env bash
# Builds a self-contained local copy of Robinhood Chain mainnet with Ledgerline deployed and seeded,
# for frontend development and manual testing.
#
# Why a snapshot: the public RPC is not an archive node, so an anvil fork pinned to a block starts
# failing ("historical state ... is not available") once that block ages out. We fork at head,
# deploy + seed + touch every read path the app uses, dump anvil's state, then serve that state
# from a non-forking anvil (chain id 4663) that never needs the upstream RPC again.
#
# Usage:  scripts/fork-snapshot.sh            # builds .fork/state.json and serves it on :8711
#         PORT=8711 scripts/fork-snapshot.sh serve   # serve an existing snapshot
# Env:    ANVIL / FORGE override binaries; UPSTREAM overrides the mainnet RPC.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANVIL="${ANVIL:-anvil}"
FORGE="${FORGE:-forge}"
PORT="${PORT:-8711}"
UPSTREAM="${UPSTREAM:-https://rpc.mainnet.chain.robinhood.com}"
RPC="http://127.0.0.1:${PORT}"
STATE_DIR="$ROOT/.fork"
STATE="$STATE_DIR/state.json"
# Not a key: an arbitrary address, impersonated via --auto-impersonate.
DEPLOYER="0x1000000000000000000000000000000000000001"
mkdir -p "$STATE_DIR"

rpc() { curl -s -m 120 -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$RPC"; }
wait_up() { for _ in $(seq 1 60); do rpc eth_chainId '[]' | grep -q 0x1237 && return 0; sleep 1; done; echo "anvil did not start" >&2; exit 1; }

serve() {
  echo "Serving snapshot $STATE on $RPC (chain 4663, no upstream)"
  exec "$ANVIL" --load-state "$STATE" --chain-id 4663 --port "$PORT" --auto-impersonate --silent
}

if [[ "${1:-}" == "serve" ]]; then serve; fi

echo "1/5 forking $UPSTREAM at head on :$PORT"
"$ANVIL" --fork-url "$UPSTREAM" --auto-impersonate --port "$PORT" --timeout 120000 --retries 20 --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
wait_up
rpc anvil_setBalance "[\"$DEPLOYER\",\"0x56BC75E2D63100000\"]" >/dev/null

cd "$ROOT/contracts"
echo "2/5 deploying (script/Deploy.s.sol)"
DEPLOYMENT_NAME=4663-fork "$FORGE" script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --unlocked --sender "$DEPLOYER" --broadcast --slow >"$STATE_DIR/deploy.log" 2>&1 \
  || { tail -20 "$STATE_DIR/deploy.log"; exit 1; }
echo "3/5 seeding demo positions (script/SeedFork.s.sol)"
DEPLOYMENT_NAME=4663-fork "$FORGE" script script/SeedFork.s.sol:SeedFork --rpc-url "$RPC" --unlocked --sender "$DEPLOYER" --broadcast --slow >"$STATE_DIR/seed.log" 2>&1 \
  || { tail -20 "$STATE_DIR/seed.log"; exit 1; }

echo "4/5 warming every read path the frontend uses"
node "$ROOT/scripts/warm-fork.mjs" "$RPC" "$ROOT/deployments/4663-fork.json"

echo "5/5 dumping state"
rpc anvil_dumpState '[]' | node -e '
  const zlib = require("zlib"); let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    const hex = JSON.parse(s).result.slice(2);
    require("fs").writeFileSync(process.argv[1], zlib.gunzipSync(Buffer.from(hex, "hex")));
  });' "$STATE"
kill $ANVIL_PID; wait $ANVIL_PID 2>/dev/null || true
trap - EXIT
echo "Snapshot written to $STATE"
serve
