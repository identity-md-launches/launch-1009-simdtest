// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable, single-pool paired-currency fees. Accrual is held as ERC-6909 claims.
contract SIMDTESTHook is IUnlockCallback {
    error OnlyPoolManager();
    error OnlySelf();
    error InvalidDeployment();
    error InvalidPool();
    error AlreadyInitialized();
    error NotInitialized();
    error BatchTooSoon();
    error NoDonation();
    error UnexpectedUnlock();
    error ReentrantCall();
    error UnrepresentableFee();
    error QuoteResult(uint256 pairedAmount);

    address public constant PAIRED_CURRENCY = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant VAULT = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant ANTI_SNIPE_BLOCKS = 10;
    uint256 public constant INITIAL_ANTI_SNIPE_BPS = 3_000;
    uint256 public constant GROWTH_BPS = 50;
    uint256 public constant BATCH_INTERVAL = 3_600;
    uint256 private constant BPS = 10_000;
    uint160 public constant FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);

    IPoolManager public immutable poolManager;
    address public immutable token;
    bool public immutable pairedIs0;
    bool public initialized;
    uint256 public openingBlock;
    uint256 public pending;
    uint256 public antiSnipePending;
    uint256 public lastBatch;
    bool private operating;
    bool private unlockExpected;

    event Opened(uint256 indexed blockNumber, uint256 timestamp);
    event FeesAccrued(uint256 antiSnipe, uint256 liquidityGrowth);
    event Swept(address indexed caller, uint256 amount);
    event Donated(address indexed caller, uint256 amount, uint256 timestamp);

    constructor(IPoolManager manager_, address token_) {
        if (address(manager_).code.length == 0 || token_.code.length == 0 || token_ == PAIRED_CURRENCY) {
            revert InvalidDeployment();
        }
        poolManager = manager_;
        token = token_;
        pairedIs0 = PAIRED_CURRENCY < token_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (operating) revert ReentrantCall();
        operating = true;
        _;
        operating = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(pairedIs0 ? PAIRED_CURRENCY : token),
            currency1: Currency.wrap(pairedIs0 ? token : PAIRED_CURRENCY),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (initialized) revert AlreadyInitialized();
        PoolKey memory expected = poolKey();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(expected.toId())) revert InvalidPool();
        initialized = true;
        openingBlock = block.number;
        lastBatch = block.timestamp;
        emit Opened(block.number, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function antiSnipeBps() public view returns (uint256) {
        if (!initialized) return 0;
        uint256 elapsed = block.number - openingBlock;
        return elapsed >= ANTI_SNIPE_BLOCKS ? 0 : INITIAL_ANTI_SNIPE_BPS - elapsed * 300;
    }

    /// @dev The specified currency is charged here; unspecified currency is charged afterSwap.
    /// A rollback-only quote handles partial fills and int256 requests without narrowing them.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_pairSpecified(params)) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        uint256 requested = _abs(params.amountSpecified);
        (uint256 anti, uint256 growth) = _fees(requested, params.amountSpecified > 0);
        uint256 fee = anti + growth;
        if (fee == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        bool exactInput = params.amountSpecified < 0;
        uint256 target = exactInput ? requested - fee : requested + fee;
        if (target > uint256(type(int256).max)) revert UnrepresentableFee();
        SwapParams memory quoted = SwapParams({
            zeroForOne: params.zeroForOne,
            amountSpecified: exactInput ? -int256(target) : int256(target),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });
        uint256 executed = _quote(key, quoted);
        // The price limit can leave most of a large request unfilled. Charge only its filled share.
        if (executed < target) {
            anti = FullMath.mulDiv(executed, anti, target);
            growth = FullMath.mulDiv(executed, growth, target);
        }
        fee = _accrue(anti, growth);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (_pairSpecified(params)) return (IHooks.afterSwap.selector, 0);
        uint256 base = _abs(pairedIs0 ? int256(delta.amount0()) : int256(delta.amount1()));
        (uint256 anti, uint256 growth) = _fees(base, params.amountSpecified > 0);
        uint256 fee = _accrue(anti, growth);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @dev Both rates apply to gross IMD: total input on buys, pre-fee output on sells.
    /// Exact-output paths supply net IMD (core input on buys, trader output on sells),
    /// so both reserves share the combined-rate gross-up denominator. Round each down.
    function _fees(uint256 amount, bool exactOutput) private view returns (uint256 anti, uint256 growth) {
        uint256 antiBps = antiSnipeBps();
        uint256 denominator = exactOutput ? BPS - antiBps - GROWTH_BPS : BPS;
        anti = FullMath.mulDiv(amount, antiBps, denominator);
        growth = FullMath.mulDiv(amount, GROWTH_BPS, denominator);
    }

    /// @notice Anyone can redeem all accrued anti-snipe claims to the fixed vault.
    function sweep() external nonReentrant returns (uint256 amount) {
        amount = antiSnipePending;
        if (amount == 0) return 0;
        // Keep each manager delta representable. Any excess remains sweepable in another call.
        if (amount > uint256(uint128(type(int128).max))) amount = uint256(uint128(type(int128).max));
        antiSnipePending -= amount;
        _unlock(false, amount);
        emit Swept(msg.sender, amount);
    }

    /// @notice Donate half the growth reserve, rounded down, at most once each hour.
    function donateBatch() external nonReentrant returns (uint256 amount) {
        if (!initialized) revert NotInitialized();
        if (block.timestamp - lastBatch < BATCH_INTERVAL) revert BatchTooSoon();
        amount = pending / 2;
        if (amount == 0) revert NoDonation();
        if (amount > uint256(uint128(type(int128).max))) amount = uint256(uint128(type(int128).max));
        pending -= amount;
        lastBatch = block.timestamp;
        _unlock(true, amount);
        emit Donated(msg.sender, amount, block.timestamp);
    }

    function _unlock(bool donate, uint256 amount) private {
        unlockExpected = true;
        poolManager.unlock(abi.encode(donate, amount));
        unlockExpected = false;
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!unlockExpected) revert UnexpectedUnlock();
        unlockExpected = false;
        (bool donate, uint256 amount) = abi.decode(data, (bool, uint256));
        // Burning a claim credits the hook's delta. Donation/take debits exactly the same amount.
        poolManager.burn(address(this), uint160(PAIRED_CURRENCY), amount);
        if (donate) {
            poolManager.donate(poolKey(), pairedIs0 ? amount : 0, pairedIs0 ? 0 : amount, "");
        } else {
            poolManager.take(Currency.wrap(PAIRED_CURRENCY), VAULT, amount);
        }
        return "";
    }

    /// @dev Only this hook can simulate. The revert rolls back the entire nested swap, including
    /// price, fee growth, claims and transient deltas; no simulated trade ever survives on chain.
    function quotePairDelta(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert QuoteResult(_abs(pairedIs0 ? int256(delta.amount0()) : int256(delta.amount1())));
    }

    function _quote(PoolKey calldata key, SwapParams memory params) private returns (uint256 amount) {
        try this.quotePairDelta(key, params) {
            // quotePairDelta always reverts.
            revert UnrepresentableFee();
        } catch (bytes memory reason) {
            if (reason.length == 36 && bytes4(reason) == QuoteResult.selector) {
                assembly ("memory-safe") { amount := mload(add(reason, 36)) }
            } else {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
        }
    }

    function _pairSpecified(SwapParams calldata params) private view returns (bool) {
        return (params.amountSpecified < 0 == params.zeroForOne) == pairedIs0;
    }

    function _abs(int256 value) private pure returns (uint256) {
        unchecked {
            return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
        }
    }

    function _accrue(uint256 anti, uint256 growth) private returns (uint256 fee) {
        fee = anti + growth;
        if (fee == 0) return 0;
        // Actual swap deltas bound fee below int128.max; no cast of the requested int256 occurs.
        antiSnipePending += anti;
        pending += growth;
        poolManager.mint(address(this), uint160(PAIRED_CURRENCY), fee);
        emit FeesAccrued(anti, growth);
    }
}
