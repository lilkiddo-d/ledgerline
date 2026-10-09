// Makes an anvil fork self-contained before its state is dumped.
//
// anvil's dump only contains accounts modified locally; code and storage merely *read* from the
// upstream fork (token implementations behind proxies, Chainlink aggregators, Multicall3...) are left
// out, so a snapshot served without upstream would see empty code. This script traces every read and
// write path the frontend uses with `prestateTracer` (simulated, nothing is committed), then writes
// each touched contract's code and storage back with anvil_set* so it becomes local state.
//
// Usage: node warm-fork.mjs <rpc> <deployment.json>
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

// viem is installed in the app workspace
const appRequire = createRequire(join(dirname(fileURLToPath(import.meta.url)), "..", "app", "package.json"));
const { encodeFunctionData, parseAbi, maxUint256 } = appRequire("viem");

const [rpc, deploymentPath] = process.argv.slice(2);
const dep = JSON.parse(readFileSync(deploymentPath, "utf8"));
const c = dep.contracts;

let id = 0;
async function send(method, params) {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
  });
  return res.json();
}

const erc20 = parseAbi([
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function name() view returns (string)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
]);
const poolAbi = parseAbi([
  "function supply(address,uint256,address) returns (uint256)",
  "function withdraw(address,uint256,address) returns (uint256)",
  "function borrow(address,uint256) returns (uint256)",
  "function repay(address,uint256,address) returns (uint256)",
  "function liquidate(address,address,address,uint256,bool) returns (uint256,uint256)",
  "function setUseAsCollateral(address,bool)",
  "function setEMode(uint8)",
]);
const lensAbi = parseAbi([
  "function getMarkets() view",
  "function getUserPositions(address) view",
  "function getHealthFactors(address[]) view",
]);
const miscAbi = parseAbi(["function latestRoundData() view", "function getChainId() view returns (uint256)"]);

const u = (s) => ("0x" + "0".repeat(38) + s).toLowerCase();
const [LP, DEV, BOB, CAROL, DAVE, LIQ] = ["A1", "A2", "B0", "C0", "D0", "E0"].map(u);
const users = [LP, DEV, BOB, CAROL, DAVE, LIQ];
const usdg = dep.assets.find((a) => !a.isStock);
const nvda = dep.assets.find((a) => a.symbol === "NVDA");

const calls = [];
const add = (from, to, abi, functionName, args = []) =>
  calls.push({ from, to, data: encodeFunctionData({ abi, functionName, args }) });

add(LP, "0xcA11bde05977b3631167028862bE2a173976CA11", miscAbi, "getChainId");
add(LP, c.PoolLens, lensAbi, "getMarkets");
for (const x of users) add(LP, c.PoolLens, lensAbi, "getUserPositions", [x]);
add(LP, c.PoolLens, lensAbi, "getHealthFactors", [users]);
for (const a of dep.assets) {
  for (const f of ["symbol", "decimals", "name", "totalSupply"]) add(LP, a.address, erc20, f);
  for (const x of users) {
    add(LP, a.address, erc20, "balanceOf", [x]);
    add(LP, a.address, erc20, "allowance", [x, c.Pool]);
  }
  add(LP, a.feed, miscAbi, "latestRoundData");
  // write paths, simulated only
  add(DEV, a.address, erc20, "approve", [c.Pool, maxUint256]);
  add(LIQ, a.address, erc20, "approve", [c.Pool, maxUint256]);
  add(LP, a.address, erc20, "transfer", [DEV, 1n]);
  const unit = 10n ** BigInt(a.decimals);
  add(LP, c.Pool, poolAbi, "supply", [a.address, unit, LP]);
  add(LP, c.Pool, poolAbi, "withdraw", [a.address, unit, LP]);
  add(LP, c.Pool, poolAbi, "borrow", [a.address, 1n]);
  add(BOB, c.Pool, poolAbi, "repay", [a.address, 1n, BOB]);
}
add(LIQ, c.Pool, poolAbi, "liquidate", [nvda.address, usdg.address, DAVE, maxUint256, false]);
add(LIQ, c.Pool, poolAbi, "liquidate", [nvda.address, usdg.address, DAVE, maxUint256, true]);
add(DEV, c.Pool, poolAbi, "setEMode", [1]);
add(BOB, c.Pool, poolAbi, "setUseAsCollateral", [usdg.address, true]);

// 1. collect the pre-state of every touched account
const accounts = new Map(); // addr -> { code, storage: Map }
let traced = 0;
for (const call of calls) {
  const r = await send("debug_traceCall", [call, "latest", { tracer: "prestateTracer" }]);
  if (r.error || !r.result) continue;
  traced++;
  for (const [addr, st] of Object.entries(r.result)) {
    const acc = accounts.get(addr) ?? { code: undefined, storage: new Map() };
    if (st.code && st.code !== "0x") acc.code = st.code;
    for (const [k, v] of Object.entries(st.storage ?? {})) acc.storage.set(k, v);
    accounts.set(addr, acc);
  }
}

// 2. pin it as local state (contracts only; EOAs keep whatever is already local)
let pinnedCode = 0, pinnedSlots = 0;
for (const [addr, acc] of accounts) {
  if (!acc.code) continue;
  if (!(await send("anvil_setCode", [addr, acc.code])).error) pinnedCode++;
  for (const [k, v] of acc.storage) {
    if (!(await send("anvil_setStorageAt", [addr, k, v])).error) pinnedSlots++;
  }
}

// 3. sanity check
const check = await send("eth_call", [{ to: c.PoolLens, data: encodeFunctionData({ abi: lensAbi, functionName: "getMarkets" }) }, "latest"]);
console.log(`traced ${traced}/${calls.length} paths; pinned code for ${pinnedCode} contracts and ${pinnedSlots} storage slots`);
if (check.error) {
  console.error("getMarkets still fails:", check.error.message);
  process.exitCode = 1;
}
