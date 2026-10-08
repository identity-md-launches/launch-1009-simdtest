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
| Fee rate / ordering | Two reserves cannot cross-fund each other; 30% decreases by 3 percentage points per block for ten blocks, plus constant 0.5%, both on gross IMD. Exact-output paths gross up using the combined rate. Equivalent-trade tests compare both reserves and settlements from identical state for buys, sells, partial fills and both currency orderings. |
| Reentrancy | Maintenance uses a shared guard, effects before manager unlock and a one-use expected-callback flag. Swap accrual calls only the fixed manager's claim mint; no ERC-20, vault or arbitrary router call occurs. |
| Recipient failure | A reverted vault transfer restores anti-snipe claims. Fees remain collectable and subsequent swaps work. |
| Donation griefing | Empty/dust/no-liquidity failures cannot consume the timer or reserve. A second successful donation requires 3600 seconds. Concurrent transactions serialize through the stored timestamp. |
| Arithmetic | Percentages use FullMath for int256 request magnitudes. int256.min magnitude is computed without signed negation overflow. Delta-based multiplication is bounded by int128. Maintenance caps avoid delta casts above int128.max. |
| Supply and settlement | Entire 1e27 supply is minted once to deployer. ERC-20 transfer/transferFrom conservation fuzzed. No mint/admin selectors work; transfers to PoolManager are untaxed. |
| Finality | Token and hook runtime are scanned with PUSH data skipped, rejecting SELFDESTRUCT, DELEGATECALL and CALLCODE. Runtime <= EIP-170 and creation code plus arguments <= EIP-3860. No owner, proxy, setter or upgrade path exists. |

The arithmetic bound for a specified-side fee follows from the actual quote delta. For exact input, `(A+G)/T <= 3050/6950`; for exact output the ratio is at most `3050/10000`. Multiplying those ratios by the int128-bounded executed delta fits the positive int128 fee field. Unspecified-side fees are at most `3050/10000` of the core IMD output for exact-input sells and `3050/6950` of the core IMD input for exact-output buys. The latter fraction grosses up to 30.5% of total IMD paid. Both fractions fit the positive int128 fee field. Core/router settlement arithmetic remains subject to v4's inherent representation limits.

The positive exact-output exclusion is tested with the precise nested v4 error encoding for UnrepresentableFee. Legitimate core errors, such as an invalid price limit, are propagated rather than swallowed by the quote catch. The extra quote can increase gas materially for swaps crossing many ticks; it never scans user-controlled arrays in the hook and is constrained by the same price limit as the real swap.

## Executed evidence and outstanding checks

- Solidity 0.8.26, Cancun, optimizer enabled, metadata bytecode hash disabled.
- Local real-PoolManager unit and fuzz tests, runtime scans, and stateful reserve/claim conservation checks.
- All 11 supplied protected checks passed when run unchanged from scratch copies against the compiled creation code, with the mainnet manager address instantiated locally and explicit test-only factory/token probes.
- Measured token creation/runtime: 2592/1722 bytes. Revised hook creation/runtime: 8099/7162 bytes; constructor arguments add 64 bytes to init code.
- Both ordinary and fresh token-only pool funding paths, partial fills, donation earnings and failure rollback.
- Offline dependency closure and launch manifest consistency checks.
- Fork tests delivered but not executed against mainnet: public RPC requests returned HTTP 403. Local mocks cannot establish the deployed IMD token's actual transfer restrictions, upgrades or other behavior.
- No Slither, Mythril, formal verification, independent audit or live launch-factory allocation test was run. These are not represented as passing checks.

## Revision findings

- Fee basis (`02e651d8a8e5ec1caedb700a68e531c6f7b38ef91cc10578cb87ea007fdf7769`): reproduced the supplied proof's opening-block fees of 30.5 IMD for exact input versus 21.1975 IMD for equivalent exact output. Fixed both exact-output paths with the combined-rate gross-up. The supplied proof now passes. The fee fixture now checks actual gross settlement independently of swap mode, and equivalent-trade regressions cover buys and sells, both currency orders, partial fills, and each launch rate.
- Donation recipients (`16a7c3d5ddd405e487dec41ca4130f91871addbaf2cb5f982092ce24ef9372a4`): reproduced the supplied proof's JIT gain of 49.876579736155261474 IMD out of a 49.926456315891416737 IMD donation. Disputed its asserted protection for historical LPs: the brief explicitly requests permissionless hourly PoolManager donations benefiting in-range LPs, without an age criterion. Pool.donate distributes fee growth using current active liquidity. A new in-range LP satisfies that rule. The proof's at-most-half capture assertion is an additional economic requirement. No donation or liquidity-access behavior was changed. Streaming, a minimum holding period, historical rewards, or a hook-owned position would require a revised payout specification. The capture remains a documented material limitation, not a fixed vulnerability or a non-reproduction claim.

The supplied `launch.json` already had the valid `univ4_hook` discriminator; that earlier analysis failure did not reproduce. JSON parsing and required manifest values were checked, and only the explanatory fee/donation notes changed.

The specified preset permits public donation timing and rewards whichever LPs are in range at execution. It has no JIT-liquidity defense, keeper subsidy, rescue authority, or pause. The reviewer proof demonstrated approximately 99.9% capture by a same-transaction position with 1000 times the seed's in-range liquidity. A sole in-range position receives the entire batch, less rounding, regardless of age or how little liquidity it supplies. `test/DonationRecipients.t.sol` characterizes these outcomes, including preservation of funds and timer when no in-range liquidity exists. This limitation remains unresolved by the preset: the hook does not promise historical-LP rewards, principal growth or irreversible liquidity locking. Unsolicited tokens/claims are not included in pending counters and cannot be recovered through an admin function.
