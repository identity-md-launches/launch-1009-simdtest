# SIMDTEST launch tests

Run the complete offline suite with `forge build` and `forge test`. The dependencies already
vendored by the project are sufficient; these additions require no downloads or configuration
changes. Local runs for this assignment place compiler output and caches in scratch:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test
```

The original token, hook, fork, and accounting suites remain in place. Additional coverage:

| Suite | Properties checked |
| --- | --- |
| `HookAdversarial.t.sol` | Invalid constructor inputs; wrong pool and invalid-price initialization rollback; zero swaps and failed settlement; one-wei donation dust; liquidity removal/retry; in-range LP earnings; permissionless keeper events; administrative selector refusal. |
| `HookDifferential.t.sol` | All four swap modes and both currency orderings against a real hook-free control pool with identical liquidity and the static 1.25% LP fee. Checks token deltas, exact output, fee amounts, prices, and LP fee growth. Exercises integer thresholds and price-limited partial fills. |
| `HookBatch.t.sol` | Eight swaps with settlement deferred until the end of one unlock versus eight individually settled swaps, including quote rollback while other deltas are outstanding. A failing final swap must roll back earlier trades and accrual. |
| `FeeLifecycleInvariant.t.sol` | Independent fee model over swaps, block/time advances, sweeps, successful and failing donations, LP withdrawal/redeposit, and deliberately unsettled swaps. Checks reserves, vault receipts, donation timing, global token conservation, and settled manager deltas. |
| `MainnetFork.t.sol` additions | Failed settlement and cooldown preservation using real IMD; removing LP liquidity, sweeping after a failed donation, and successfully retrying donation after liquidity returns. |

Each new fuzz property runs 1,000 cases. The new invariant runs 256 sequences of depth 64,
with unexpected reverts treated as failures. Expected failures are asserted inside the handler.
Its fees are calculated from specified IMD budgets and elapsed blocks, independently of the
hook's counters. Trades pause while the handler has removed liquidity; after redeposit they
resume. Amount bounds keep this invariant's trades fully fillable; separate differential tests
cover partial fills, and the original suite covers very large signed requests.

The local fixtures use the actual v4 `PoolManager` implementation and directly CREATE2-deployed
hooks with mined permission bits. Only IMD is replaced with a standard ERC20 locally. The
mainnet suite preserves deployed PoolManager and IMD code and checks chain ID, symbol, and
decimals. Supply invariants do not mint or reset balances during random sequences.

## Mainnet fork validation

The fork suite requires an externally supplied Ethereum RPC and an explicit block at which IMD
and PoolManager exist. It is skipped in the default offline run:

```sh
forge test --fork-url "$MAINNET_RPC_URL" --fork-block-number "$MAINNET_BLOCK" --match-contract MainnetForkTest
```

Live fork execution was unavailable during this assignment: both public RPC endpoints attempted
returned HTTP 403. The fork additions compile, but their execution against mainnet remains
unverified. A skipped fork is not reported as a passed integration test. No RPC credentials or
new dependencies are included.

No reproducible implementation defect was found by the added local checks. Administrative
selector probes and the existing opcode scan cover the reviewed interfaces and runtime; they
are not a general proof that arbitrary contracts lack backdoors.
