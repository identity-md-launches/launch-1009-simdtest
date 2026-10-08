# Implementation review

This is the contributor's local adversarial review, not an independent audit. No transactions were broadcast. Independent review and a successful mainnet rehearsal are release responsibilities.

## Reviewed boundaries

| Surface | Evidence / result |
| --- | --- |
| Callback authority | beforeInitialize, beforeSwap, afterSwap and unlockCallback reject non-manager callers. Unexpected manager unlock callbacks also reject. |
| Initialization | Exact token, IMD, static 12500 fee, spacing 60, and self hook identity are bound. Failed initialization does not bind state. No price restriction blocks factory economics. |
| Permissions | Only beforeInitialize, beforeSwap, afterSwap and the two swap return-delta flags are set: 0x20cc. Real CREATE2 deployment validates them; invalid bits refuse construction. |
| No-op theft | beforeSwap returns only the fee, never cancels a whole real swap. Fee-free dust returns zero; zero execution produces zero fees. Real pool swaps provide output and advance the pool price. |
| Quote isolation | The quote entry point is self-only and always reverts. PoolManager sees the hook as swap sender and skips callbacks. No arbitrary target, delegated call, user-controlled quote data, or externally callable fee-exempt trading path exists. |
| Delta conservation | Fee claim mint equals the positive hook return delta. Sweep burns then takes equal IMD. Donation burns then donates equal IMD. Swaps on empty-IMD managers and all four trade modes close without CurrencyNotSettled. |
| Partial fills | Only the executed share pays specified-side fees; original sqrtPriceLimitX96 is retained. Fuzzing spans amounts above int128 and near int256 limits. int256.min exact input partially fills. |
| Fee rate / ordering | Two reserves cannot cross-fund each other; 30% decreases by 3 percentage points per block for ten blocks, plus constant 0.5%. Both currency orderings pass. |
| Reentrancy | Maintenance uses a shared guard, effects before manager unlock and a one-use expected-callback flag. Swap accrual calls only the fixed manager's claim mint; no ERC-20, vault or arbitrary router call occurs. |
| Recipient failure | A reverted vault transfer restores anti-snipe claims. Fees remain collectable and subsequent swaps work. |
| Donation griefing | Empty/dust/no-liquidity failures cannot consume the timer or reserve. A second successful donation requires 3600 seconds. Concurrent transactions serialize through the stored timestamp. |
| Arithmetic | Percentages use FullMath for int256 request magnitudes. int256.min magnitude is computed without signed negation overflow. Delta-based multiplication is bounded by int128. Maintenance caps avoid delta casts above int128.max. |
| Supply and settlement | Entire 1e27 supply is minted once to deployer. ERC-20 transfer/transferFrom conservation fuzzed. No mint/admin selectors work; transfers to PoolManager are untaxed. |
| Finality | Token and hook runtime are scanned with PUSH data skipped, rejecting SELFDESTRUCT, DELEGATECALL and CALLCODE. Runtime <= EIP-170 and creation code plus arguments <= EIP-3860. No owner, proxy, setter or upgrade path exists. |

The arithmetic bound for a specified-side fee follows from the actual quote delta. For exact input, `(A+G)/T <= 3050/6950`; for exact output the ratio is at most `3050/13050`. Multiplying those ratios by the int128-bounded executed delta fits the positive int128 fee field. Unspecified-side fees are at most 30.5% of an int128 magnitude. Core/router settlement arithmetic remains subject to v4's inherent representation limits.

The positive exact-output exclusion is tested with the precise nested v4 error encoding for UnrepresentableFee. Legitimate core errors, such as an invalid price limit, are propagated rather than swallowed by the quote catch. The extra quote can increase gas materially for swaps crossing many ticks; it never scans user-controlled arrays in the hook and is constrained by the same price limit as the real swap.

## Executed evidence and outstanding checks

- Solidity 0.8.26, Cancun, optimizer enabled, metadata bytecode hash disabled.
- Local real-PoolManager unit and fuzz tests, runtime scans, and stateful reserve/claim conservation checks.
- All 11 supplied protected checks passed when run unchanged from scratch copies against the compiled creation code, with the mainnet manager address instantiated locally and explicit test-only factory/token probes.
- Measured token creation/runtime: 2592/1722 bytes. Hook creation/runtime: 8056/7119 bytes; constructor arguments add 64 bytes to init code.
- Both ordinary and fresh token-only pool funding paths, partial fills, donation earnings and failure rollback.
- Offline dependency closure and launch manifest consistency checks.
- Fork tests delivered but not executed against mainnet: public RPC requests returned HTTP 403. Local mocks cannot establish the deployed IMD token's actual transfer restrictions, upgrades or other behavior.
- No Slither, Mythril, formal verification, independent audit or live launch-factory allocation test was run. These are not represented as passing checks.

The specified preset deliberately permits public donation timing and rewards whichever LPs are in range at execution. It has no JIT-liquidity defense, keeper subsidy, rescue authority, or pause. The hook does not promise principal growth or irreversible liquidity locking. Unsolicited tokens/claims are not included in pending counters and cannot be recovered through an admin function.
