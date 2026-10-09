// Touches every contract read the frontend performs so the anvil fork caches the needed state
// before it is dumped. Usage: node warm-fork.mjs <rpc> <deployment.json>
import { readFileSync } from "node:fs";

const [rpc, deploymentPath] = process.argv.slice(2);
const dep = JSON.parse(readFileSync(deploymentPath, "utf8"));

// 4-byte selectors (keccak256 of the signature).
const SEL = {
  getMarkets: "0xec2c9016",
  getUserPositions: "0x2a6bc2dd",
  symbol: "0x95d89b41",
  decimals: "0x313ce567",
  name: "0x06fdde03",
  totalSupply: "0x18160ddd",
  balanceOf: "0x70a08231",
  allowance: "0xdd62ed3e",
  oraclePaused: "0x7706ba52",
  paused: "0x5c975abb",
  latestRoundData: "0xfeaf968c",
};

let id = 0;
async function call(to, data) {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "eth_call", params: [{ to, data }, "latest"] }),
  });
  const j = await res.json();
  return j.error ? null : j.result;
}
const pad = (a) => a.toLowerCase().replace("0x", "").padStart(64, "0");

const users = ["A1", "A2", "B0", "C0", "D0", "E0"].map((s) => "0x" + "0".repeat(38) + s);
const pool = dep.contracts.Pool;
let ok = 0, fail = 0;
const track = (r) => (r === null ? fail++ : ok++);

// Multicall3 (wagmi batches reads through it): loads its code into the snapshot.
track(await call("0xcA11bde05977b3631167028862bE2a173976CA11", "0x3408e470"));
track(await call(dep.contracts.PoolLens, SEL.getMarkets));
for (const u of users) track(await call(dep.contracts.PoolLens, SEL.getUserPositions + pad(u)));
for (const a of dep.assets) {
  for (const s of [SEL.symbol, SEL.decimals, SEL.name, SEL.totalSupply, SEL.paused, SEL.oraclePaused]) await call(a.address, s);
  for (const u of users) {
    track(await call(a.address, SEL.balanceOf + pad(u)));
    track(await call(a.address, SEL.allowance + pad(u) + pad(pool)));
  }
  track(await call(a.feed, SEL.latestRoundData));
}
console.log(`warmed: ${ok} ok, ${fail} failed`);
if (fail > 0) process.exitCode = 1;
