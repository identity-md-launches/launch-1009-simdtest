# SIMDTEST liquidity growth launch

This Foundry project delivers the plain fixed-supply `SIMDTEST` ERC-20 and the directly deployed `SIMDTESTHook`. `launch.json` uses the `univ4_hook` discriminator and names the hook itself. All imported Solidity dependencies and licenses are vendored as ordinary files under `lib/`; no submodules, package downloads, FFI, filesystem cheatcode permissions, or environment variables are needed by the default test run.

## Fixed launch parameters

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| Hook constructor | `(IPoolManager manager_, address token_)` |
| Mainnet manager argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Manifest constructor arguments | `["$poolManager", "$token"]` |
| Pair | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| Anti-snipe vault | `0x3dd5f73dd1a4e62630fad3909673f130ad429985` |
| Name / symbol | SIMDTEST / SIMDTEST |
| Supply | 1,000,000,000 tokens, 18 decimals (`1e27` units) |
| Pool LP fee / spacing | 12500 (1.25%) / 60 |
| Manifest opening price | `79228162514264337593543950336` (sqrtPriceX96 provenance) |
| Hook address bits | `0x20cc` (8396), lower 14 bits |
| Growth fee | 50 basis points (0.5%) |
| Donation interval / maximum | 3600 seconds / 50% of pending growth fees |

`SIMDTEST` has a zero-argument constructor and mints the **entire** supply to its deployer. The factory handles the swarm's 10% Merkle allocation, 90% pool seed, and any launch-policy remainder to `remainderTo`. Neither delivered contract sends a swarm allocation. There is no subsequent mint, burn, transfer tax, owner, administrator, pause, upgrade, proxy, or fee setter. ERC-20 transfers and approvals follow OpenZeppelin ERC20, including transfers to PoolManager.

The hook stores the manager, token and currency ordering immutably. The IMD address, vault and economic parameters are constants. Only the exact token/IMD pool with the static fee, spacing and this hook can initialize. Initialization is restricted to calls from PoolManager and records the opening block and timestamp. It accepts the factory's economics-derived price; the provenance price does not constrain it. There is no administrator even during initialization.

## Fee accounting

For opening block `B`, the anti-snipe rate at blocks `B` through `B+9` is respectively **30%, 27%, 24%, 21%, 18%, 15%, 12%, 9%, 6%, 3%**. At `B+10` and later it is zero. The growth fee is always 0.5%; the maximum combined hook rate is 30.5%, separate from the pool's static 1.25% LP fee. The hook returns zero for the LP-fee override word and never updates the LP fee.

All hook fees are denominated in IMD. The launch token is never taxed or retained by the hook. Both rates use **gross IMD** in every swap mode: the trader's total IMD input on a buy, or the pool's IMD output before hook fees on a sell. Charges round down separately for the two reserves, so sub-unit fees can be zero.

| Swap | IMD side / fee basis | Callback |
| --- | --- | --- |
| Exact-input buy | Specified gross IMD input budget | beforeSwap |
| Exact-output sell | Specified net IMD output, grossed up by the combined rate | beforeSwap |
| Exact-output buy | Actual core IMD input, grossed up by the combined rate | afterSwap |
| Exact-input sell | Actual core IMD output, before hook fees | afterSwap |

Let `a` be the current anti-snipe basis points and `D=10000-a-50`. For a specified IMD amount `S`, exact-input buys pay `A=floor(S*a/10000)` and `G=floor(S*50/10000)` with core input `T=S-A-G`. Exact-output sells request net IMD, so they pay `A=floor(S*a/D)` and `G=floor(S*50/D)` with core output `T=S+A+G`. This preserves the gross exact-input budget and net exact-output amount for full fills. Both fees share the combined-rate denominator; grossing each up independently would undercharge.

To support price-limit partial fills, beforeSwap performs a **rollback-only quote** of `T` against the same PoolManager, pool and user price limit. The quote is callable only by this hook, always reverts with its result, and retains no simulated swap, price change, event, LP fee growth or transient debt. v4 skips self-initiated hook callbacks, so this simulation cannot recurse. If core execution fills only `E<T`, charges become `floor(E*A/T)` and `floor(E*G/T)`; otherwise the nominal charges apply. Returning those charges lets the real swap execute normally. Rounding may differ from applying the percentage to the final partial user delta by at most a few raw units. Nothing charges the enormous unfilled remainder of a request. This requires additional swap-computation gas on the specified-IMD paths.

For unspecified IMD with absolute core delta `C`, exact-input sells pay `floor(C*a/10000)` and `floor(C*50/10000)`. Exact-output buys pay `floor(C*a/D)` and `floor(C*50/D)` on top of the core input. At the opening block, a 100 IMD exact-input buy sends 69.5 IMD to the core and accrues 30 IMD for the vault plus 0.5 IMD for growth. Buying the same output with exact output from the same state pays the same amounts, up to raw-unit rounding. Independently flooring the gross-up components can differ by one raw unit per reserve from applying rates to the final rounded gross amount.

Ordinary core price limits, liquidity constraints and router settlement rules still apply. Requests are not narrowed from int256 before execution. The explicitly excluded domain is a positive specified-IMD request whose amount plus fees exceeds int256: it reverts with `UnrepresentableFee` (wrapped by v4's hook error). Actual settled deltas must also obey PoolManager's native int128 representation, as for any v4 swap.

Each callback mints an IMD ERC-6909 claim to the hook and returns an equal positive paired-currency fee delta. The claim mint debits the hook; its return delta credits it. The caller pays the corresponding fee through its normal settlement. All deltas close at unlock. **No IMD withdrawal is attempted during a swap**, including the first buy into a token-only pool. The hook holds IMD claims, rather than an ERC-20 wallet balance. No fee conversion market or external recipient call is on the swap path.

## Permissionless operations and UI

- `pending()` is the growth reserve in raw IMD units, backed by PoolManager claims.
- `antiSnipePending()` is the separate vault reserve.
- `lastBatch()` is the timestamp of initialization until the first successful donation, then the last successful donation time.
- `antiSnipeBps()` and `openingBlock()` expose the launch clock.
- `sweep()` redeems the anti-snipe reserve to the fixed vault; anyone may call it. An empty sweep returns zero. A failed IMD transfer rolls back the redemption and accounting, without affecting swap availability.
- `donateBatch()` becomes available 3600 seconds after initialization and then 3600 seconds after each successful batch. It donates `floor(pending/2)` in IMD through `PoolManager.donate`. It burns matching claims to settle the donation, leaving the other reserve untouched. Burning a claim redeems accounting credit; **no underlying token is burned**.

Each maintenance operation is capped to int128.max units to fit one manager delta; any excess remains for subsequent operations, subject to the donation timer. Calls run while PoolManager is locked, because they initiate an unlock. Calling them from an existing unlock cannot nest the manager lock and reverts atomically. Empty donations, unavailable in-range liquidity and failed manager operations preserve the reserve and timer. One raw unit of growth fees cannot be halved and remains pending until later fees accrue.

Donation rewards LPs currently in range by increasing fee growth. It does not create or compound an LP position, change position liquidity units, or guarantee permanently locked liquidity. A keeper receives no bounty. **An LP can add liquidity, trigger an eligible batch, and remove liquidity in one transaction to capture almost all of that batch.** The supplied reviewer proof reproduced approximately 99.9% capture with 1000 times the seed's in-range liquidity. If the seed is absent or out of range, the only in-range position can collect the entire donation, less rounding, even with very little liquidity. No liquidity age or historical fee-accrual eligibility is tracked.

This is a material limitation of the requested permissionless, in-range donation preset, not a promise of long-term liquidity expansion. Historical-LP rewards, liquidity holding periods, streaming payouts or hook-owned positions would change that preset and require a revised specification. The revision response disputes the proof's historical-LP guarantee while acknowledging the demonstrated capture; donation behavior remains unchanged. Unsolicited ERC-20 or claim transfers are not booked as swap fees and have no rescue path.

## Deployment and operation

1. Build with the pinned settings. Resolve `$poolManager` to the mainnet address above and `$token` to the actual newly deployed SIMDTEST. These are launch-factory placeholders, not substitute addresses.
2. Mine against `keccak256(type(SIMDTESTHook).creationCode ++ abi.encode(manager, token))` and the **actual CREATE2 deployer**. `script/MineHook.sol` provides a pure bounded salt search. Restart at the next range if no salt is found. The constructor verifies the address bits. Changing compiler settings, constructor arguments or deployer requires mining again.
3. Have the factory deploy the token, deploy the hook directly, initialize and seed the pool atomically. There is no wrapper between the manifest and hook. Before the hook has code, its initialization permission causes PoolManager to refuse initialization; atomic deployment avoids a gap after the hook exists.
4. The factory derives opening price from launch economics, sorts the currencies, seeds liquidity and performs its allocations. No factory address or privileged wallet needs to be invented or configured here.
5. Verify deployed bytecode and parameters; publish the real token, hook, pool ID and opening block. Run the mainnet-fork rehearsal with the actual launch seeding configuration before release. Keepers may call sweep and eligible donation batches.

There are no after-launch setters or privileged operational steps. Frontends must quote the hook-inclusive swap, honor output/input slippage limits, and distinguish raw IMD claim reserves from token balances.

## Validation

```sh
forge build
forge test
forge fmt --check
```

The default suite is offline: it uses the actual vendored v4 PoolManager implementation and a test IMD ERC-20 at the specified pair address. It covers both currency orderings, all four swap modes, each early block, post-window fees, tiny amounts, price-limit partial fills including huge int256 requests, token-only initial liquidity, permission bits, authorization, sweep/donation timing and accounting, LP donation earnings, rollback on failed settlement, and runtime opcode/size checks. Equivalent-trade regression tests compare exact input with exact output from identical state, separately checking both fee reserves and both asset settlements, including partial fills. Donation tests characterize both near-total JIT capture and a sole in-range LP's capture. Fuzz tests use inline run counts; a stateful conservation invariant runs 128 sequences of 48 actions with failure on reverts.

The optional fork suite uses the real mainnet manager and IMD code and verifies chain ID, code presence, IMD symbol and decimals. It skips explicitly if no fork is active, without reading environment variables. Run with an archive RPC and a recent block where IMD is deployed:

```sh
forge test --match-contract MainnetForkTest --fork-url <archive-rpc-url> --fork-block-number <recent-mainnet-block> -vv
```

**Live fork validation remains unverified in this assignment:** the attempted public RPCs returned HTTP 403. No successful mainnet fork run is claimed. RPC credentials are not included. See `docs/SECURITY-REVIEW.md` for review evidence and limits, and `docs/DEPENDENCIES.md` for pinned dependency provenance.
