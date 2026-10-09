# Slither triage

Command: `cd contracts && slither .` (Slither 0.11.6). Config: `contracts/slither.config.json`.

**Result: 0 high, 0 medium findings.** Every contract is analyzed with complete IR (no "Impossible to generate IR" errors). The full run including low and informational findings is in `docs/slither-full-report.txt`.

```
$ slither . --exclude-low
INFO:Slither:. analyzed (64 contracts with 58 detectors), 0 result(s) found
```

## Fixed

| Detector | Location | Fix |
|---|---|---|
| (analysis gap) IR generation failed for Pool | all of `Pool` | Our `Errors` library shared its name with OpenZeppelin v5's `Errors`, which silently broke Slither's analysis of every Pool function. We renamed it to `LLErrors`. |
| `uninitialized-local` | `FeeCollector.distribute`, `PoolBase._applyDiscount` | Locals are now explicitly initialized. |
| `unused-return` | `LiquidationLogic._liquidate` (`Reserve.coverBadDebt`) | The return value is checked against the precomputed amount; a mismatch reverts. |
| `unused-return` | `ReceiptToken.withdraw` / `redeem` | Both values returned by the Pool are used; events emit the actual amounts. |
| `unused-return` | `FeeCollector.swapToStable` | The adapter's reported output is now compared too (`out >= reported`). |
| `unused-return` | `OracleAdapter._checkSequencer` | Every field is now validated: `startedAt != 0`, `updatedAt >= startedAt` and round completeness. This hardens the check as well. |

## Suppressed with justification (scoped `slither-disable-start/end` blocks)

| Detector | Location | Why it is a false positive |
|---|---|---|
| `reentrancy-no-eth` | `Pool._withdraw`, `borrow`, `repay`; `LiquidationLogic._liquidate`, `_seize`, `_writeOff` | The flagged "external calls" go to protocol-owned contracts with no callbacks: receipt/debt token mint and burn, the rate model, AssetConfig and the oracle. All of these run inside the Pool's `nonReentrant` lock. Untrusted token transfers are always the last statements. |
| `reentrancy-no-eth` | `AssetConfig.setInterestRateModel` | The calls go to the immutable, trusted Pool (`accrue`) before and after the switch, by design. |
| `reentrancy-balance` | `FeeCollector.swapToStable` | The balance diff is the intended measurement of swap output. The function is `nonReentrant` and keeper-only. |
| `reentrancy-balance` | `LiquidationLogic._liquidate` | The Reserve's balance is read to cap bad-debt coverage. The Reserve is a trusted, Pool-only contract and the call result is checked. |
| `arbitrary-send-erc20` | `FlashLoan.flashLoan` | This is ERC-3156: repayment is pulled from the receiver that approved it and returned `CALLBACK_SUCCESS`. |
| `arbitrary-send-erc20` | `LiquidationLogic._liquidate` | `q.liquidator` is always the Pool's `msg.sender`, forwarded by `Pool.liquidate`, never user-supplied. The module rejects direct calls (`OnlyDelegateCall`). |
| `unused-return` | `Pool.flashLoan`, `PoolLens._modules`, `OracleAdapter._read` | The ignored values are not needed (the module returns nothing; only 2 of 8 module addresses are used; `startedAt` is irrelevant to staleness). |
| `weak-prng`, `divide-before-multiply` | `MarketClock` calendar math | `%` derives weekdays and minutes, not randomness. Floor division is required by Howard Hinnant's civil-date algorithm. Round-trip correctness is fuzz-tested (`test_civilRoundTrip`). |

## Excluded by config

| Detector | Why |
|---|---|
| `incorrect-equality` | Every flagged `==` is an intended exact check on internal accounting: zero balances, `lastUpdate == block.timestamp`, the seized amount equalling the full position. None compares an attacker-manipulable `balanceOf` against a threshold. Pool liquidity uses internally tracked `cash`, never `balanceOf`. |

## Low and informational (not required, reviewed)

The remaining items are `timestamp` (intended: interest and market hours depend on time), `missing-zero-check` on optional module setters (zero deliberately means "disabled"), `events-maths`, `calls-loop` (bounded by `MAX_RESERVES = 32`), naming and pragma notes.
