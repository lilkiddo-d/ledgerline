# Deploying Ledgerline to Robinhood Chain mainnet

You run three commands: import a key once, deploy (and verify), and, later, activate the $LEDG token. Everything else (wiring, listings, role handover to the 48h Timelock, output files) is done by `contracts/script/Deploy.s.sol`.

> The scripts never create, request, store or print a private key. Signing happens only through the Foundry keystore account `ledgerline-deployer`, which you create in step 1.

## Pre-flight checklist

- [ ] `cast wallet list` shows `ledgerline-deployer` (step 1). No keystore by that name exists on this machine yet.
- [ ] The deployer address holds at least 0.01 ETH on chain 4663.
- [ ] You have decided on governance: a multisig address for `LEDGERLINE_GOVERNANCE`, or accept the deployer EOA.
- [ ] The dry run below ends with `SIMULATION COMPLETE`. Last run on 2026-10-09: about 65.2M gas, ~0.0026 ETH.
- [ ] `app/src/generated/deployment.json` is the empty placeholder. Step 2 fills it in.

## Before you start

- **Foundry** 1.8+ (`foundryup`). **Node** 22+ and **pnpm** 10+ are only needed for the frontend.
- The deployer address needs **ETH on Robinhood Chain (chain 4663)** for gas. The mainnet dry run estimated **~0.0027 ETH**; fund **0.01 ETH** for headroom.
- **Strongly recommended:** a multisig (e.g. a Safe on Robinhood Chain) to act as governance. It becomes the Timelock's proposer and executor, and the guardian, treasury and keeper unless you override those. If you skip this, the deployer EOA becomes governance.
- Dry-run first (no signing, no gas):

  ```bash
  cd contracts
  forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --sender 0x1000000000000000000000000000000000000001
  ```

  It should end with `SIMULATION COMPLETE` and write `deployments/4663.dryrun.json`.

## 1. Import the deployer key (once)

```bash
cast wallet import ledgerline-deployer --interactive
```

Paste the private key when prompted and choose a password. Foundry encrypts it in `~/.foundry/keystores/ledgerline-deployer`. Fund the address it prints (`cast wallet address --account ledgerline-deployer`) with ETH on chain 4663.

## 2. Deploy + verify (one command)

From the repo root (replace `0xYourGovernanceMultisig`, or drop that line to use the deployer as governance):

```bash
cd contracts && LEDGERLINE_GOVERNANCE=0xYourGovernanceMultisig forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account ledgerline-deployer --sender $(cast wallet address --account ledgerline-deployer) --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --slow --gas-estimate-multiplier 200
```

You'll be asked for the keystore password twice: once to print the sender address, once to sign.

What it does:

1. **Preflight.** Checks chain ID 4663, that every token and feed has code, the token decimals and that every live price is fresh.
2. **Deploy and wire.** Deploys Timelock (48h), AssetConfig, Pool plus its LiquidationLogic and FlashLoan modules, MarketClock (NYSE 2026–27 holidays), OracleAdapter, ComplianceRegistry (off), Reserve, FeeCollector, ProjectTokenHooks (token unset), PoolLens and two rate models.
3. **List markets.** Adds USDG plus AAPL, MSFT, NVDA, GOOGL, META, AMZN, TSLA, SPY and QQQ, with launch caps converted from USD at live prices.
4. **Hand over admin.** Gives every admin role to the Timelock and renounces the deployer's roles.
5. **Postflight.** Asserts the deployer holds nothing, the token is unset, compliance is off and the delay is at least 48h.
6. **Write outputs.** `deployments/4663.json` and the frontend config `app/src/generated/deployment.json`.
7. **Verify.** `--verify` submits every contract to Blockscout.

Optional env vars: `LEDGERLINE_GUARDIAN`, `LEDGERLINE_TREASURY`, `LEDGERLINE_KEEPER` (each defaults to governance) and `DEPLOYMENT_NAME` (output file name, default `4663`).

**Confirm the deploy landed.** The output must end with `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`. The output files are written while the script runs, so if broadcasting stopped partway they can list addresses that were never deployed. In that case, re-run with `--resume` (same command, `--resume` instead of `--broadcast`).

**If verification fails.** Blockscout sits behind a Cloudflare challenge that blocked API requests from the machine used for the dry runs, so `--verify` may fail. Your contracts are still deployed. First retry verification only (nothing is redeployed):

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account ledgerline-deployer --sender $(cast wallet address --account ledgerline-deployer) --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

If that still fails, verify manually in the browser. Run `bash scripts/verification-inputs.sh`, which writes `deployments/verify/<Contract>.json`. Then, for each address in `deployments/4663.json`, open its Blockscout page and choose **Verify & Publish** → **Solidity (Standard JSON input)**, compiler **v0.8.28**, and upload the matching file. Constructor arguments are read from the creation transaction.

Commit `deployments/4663.json` and `app/src/generated/deployment.json`. The frontend build reads the latter.

## 3. Later: activate the $LEDG token (`setProjectToken`)

`ProjectTokenHooks.setProjectToken(address)` is owner-only, one-shot, and the owner is the Timelock. You therefore **schedule** the call, wait 48h, then **execute** it. Set the addresses first (from `deployments/4663.json`):

```bash
export RPC=https://rpc.mainnet.chain.robinhood.com TIMELOCK=0x...Timelock HOOKS=0x...ProjectTokenHooks LEDG=0x...LaunchpadToken
```

**If governance is an EOA keystore** (e.g. you deployed without `LEDGERLINE_GOVERNANCE`), run the schedule now and the execute after 48h:

```bash
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $(cast calldata "setProjectToken(address)" $LEDG) 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 172800 --account ledgerline-deployer --rpc-url $RPC
```

```bash
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $(cast calldata "setProjectToken(address)" $LEDG) 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 --account ledgerline-deployer --rpc-url $RPC
```

**If governance is a Safe:** create two transactions to `$TIMELOCK` in the Safe UI (Transaction Builder → custom data). Use the calldata from:

```bash
cast calldata "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $(cast calldata "setProjectToken(address)" $LEDG) 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 172800
```

Then do the same with `execute(...)` (same arguments without the trailing delay) after 48h.

Check it worked: `cast call $HOOKS "isActive()(bool)" --rpc-url $RPC` should print `true`. Then set `NEXT_PUBLIC_PROJECT_TOKEN=$LEDG` in Vercel and redeploy the frontend. TOKEN_INTEGRATION.md has the details.

## 4. Deploy the frontend (`/app`) to Vercel

1. Push the repo, **including the `app/src/generated/deployment.json` written in step 2**, to GitHub.
2. In Vercel: **Add New → Project →** import the repo.
   - **Root Directory:** `app`
   - Framework: **Next.js** (auto-detected). Install and build commands: defaults (Vercel detects the pnpm workspace).
   - Keep **"Include files outside the root directory in the Build Step"** enabled (the default). The app imports `/config/chains.ts`.
3. Environment variables (Production):

   | Name | Value |
   |---|---|
   | `NEXT_PUBLIC_RPC_URL` | empty (public RPC) or your Alchemy URL `https://robinhood-mainnet.g.alchemy.com/v2/<key>` |
   | `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | from cloud.walletconnect.com (optional; without it only browser wallets are offered) |
   | `NEXT_PUBLIC_PROJECT_TOKEN` | empty until step 3 is executed |
   | `GEOBLOCK_COUNTRIES` | e.g. `US,CA,GB,CH`. Tokenized-stock issuer terms restrict these jurisdictions; confirm with counsel. |
   | `NEXT_PUBLIC_DEV_MOCK_ACCOUNT` | **leave unset in production** |

4. **Deploy.** Every push to `main` redeploys. To build locally first: `pnpm install && pnpm app:build`.

## Rehearse locally (what was run before handoff)

```bash
# Self-contained mainnet snapshot with Ledgerline deployed + demo positions, served on :8711
bash scripts/fork-snapshot.sh
# In another terminal: the app against it, with the impersonated "Dev account" button
printf 'NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8711\nNEXT_PUBLIC_DEV_MOCK_ACCOUNT=0x00000000000000000000000000000000000000A2\n' > app/.env.local
pnpm app:build && pnpm app:start   # http://localhost:3100
```

Before pushing, restore the production frontend config (the local rehearsal overwrites it). Either run step 2 for real, or `git checkout app/src/generated/deployment.json`.
