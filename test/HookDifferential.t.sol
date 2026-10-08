// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev The control pool independently prices the trade with the static LP fee. Comparing both
/// pools catches retained quote effects and fee calculations based on the wrong currency/delta.
abstract contract HookDifferentialBase is LaunchFixture {
    using StateLibrary for IPoolManager;
    PoolKey internal control;

    function _prepare(bool pairFirst) internal {
        _local(pairFirst, true);
        control = hook.poolKey();
        control.hooks = IHooks(address(0));
        manager.initialize(control, PRICE);
        router.liquidity(control, ModifyLiquidityParams(-600, 600, int256(LIQUIDITY), bytes32(0)));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RealCoreSwapIsExecutedExactlyOnce(bool buy, bool exactInput, uint96 raw, uint8 age) public {
        _compare(buy, exactInput, bound(raw, 1, 100 ether), bound(age, 0, 20));
    }

    function test_IntegerRoundingAtFeeThresholdsInEverySwapMode() public {
        uint256[10] memory amounts = [uint256(1), 2, 3, 4, 33, 34, 199, 200, 201, 10_001];
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 mode; mode < 4; ++mode) {
                _compare(mode < 2, mode % 2 == 0, amounts[i], 0);
            }
        }
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 mode; mode < 4; ++mode) {
                _compare(mode < 2, mode % 2 == 0, amounts[i], 10);
            }
        }
    }

    function _compare(bool buy, bool exactInput, uint256 amount, uint256 elapsed) internal {
        vm.roll(opened + elapsed);
        uint256 anti;
        uint256 growth;
        SwapParams memory params = _params(buy, exactInput, amount);
        BalanceDelta plain;
        {
            uint256 antiRate = elapsed < 10 ? (10 - elapsed) * 300 : 0;
            // Exact-output requests give net IMD (sells), or the core's IMD input (buys).
            // Recover gross IMD using both rates before calculating the separate reserves.
            uint256 denominator = exactInput ? 10_000 : 10_000 - antiRate - 50;
            // Specified IMD fees are included in the user's input budget or added to the
            // pool output needed to deliver the user's requested net IMD.
            if (buy == exactInput) {
                anti = amount * antiRate / denominator;
                growth = amount * 50 / denominator;
                params.amountSpecified += int256(anti + growth);
            }
            plain = router.swap(control, params);
            if (buy != exactInput) {
                int256 paired = _pairDelta(plain);
                uint256 executed = uint256(paired < 0 ? -paired : paired);
                anti = executed * antiRate / denominator;
                growth = executed * 50 / denominator;
            }
        }
        uint256 priorAnti = hook.antiSnipePending();
        uint256 priorGrowth = hook.pending();
        BalanceDelta taxed = router.swap(key, _params(buy, exactInput, amount));
        assertEq(hook.antiSnipePending() - priorAnti, anti, "anti-snipe must use the IMD delta");
        assertEq(hook.pending() - priorGrowth, growth, "growth must use the IMD delta");
        assertEq(_pairDelta(taxed), _pairDelta(plain) - int256(anti + growth));
        assertEq(
            hook.pairedIs0() ? taxed.amount1() : taxed.amount0(),
            hook.pairedIs0() ? plain.amount1() : plain.amount0(),
            "launch token must not be taxed"
        );
        if (exactInput) {
            int256 spent = params.zeroForOne ? int256(taxed.amount0()) : int256(taxed.amount1());
            assertEq(spent, -int256(amount), "full input budget consumed");
        } else {
            int256 received = params.zeroForOne ? int256(taxed.amount1()) : int256(taxed.amount0());
            assertEq(received, int256(amount), "exact output preserved after fees");
        }
        (uint160 actualPrice, int24 actualTick,, uint24 fee) = manager.getSlot0(key.toId());
        (uint160 controlPrice, int24 controlTick,,) = manager.getSlot0(control.toId());
        assertEq(actualPrice, controlPrice);
        assertEq(actualTick, controlTick);
        assertEq(fee, 12_500);
        (uint256 actual0, uint256 actual1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 plain0, uint256 plain1) = manager.getFeeGrowthGlobals(control.toId());
        assertEq(actual0, plain0, "quote must not persist LP fee growth");
        assertEq(actual1, plain1, "quote must not persist LP fee growth");
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PriceLimitedSwapCannotChargeForUnfilledInput(bool buy, bool exactInput, uint8 age) public {
        uint256 elapsed = bound(age, 0, 10);
        vm.roll(opened + elapsed);
        SwapParams memory params = _params(buy, exactInput, 1_000_000 ether);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-60) : int24(60));
        // Both requests are much larger than the capacity up to the limit. The bare core
        // therefore supplies an independent observation of the actually executed IMD delta.
        BalanceDelta plain = router.swap(control, params);
        BalanceDelta taxed = router.swap(key, params);
        uint256 fees = hook.pending() + hook.antiSnipePending();
        assertEq(_pairDelta(taxed) + int256(fees), _pairDelta(plain));
        assertEq(
            hook.pairedIs0() ? taxed.amount1() : taxed.amount0(), hook.pairedIs0() ? plain.amount1() : plain.amount0()
        );
        // Gross IMD is the trader's total debit on buys and the pool's pre-hook output
        // on sells, regardless of which currency was specified in the request.
        int256 basis = buy ? _pairDelta(taxed) : _pairDelta(plain);
        uint256 magnitude = uint256(basis < 0 ? -basis : basis);
        uint256 rate = elapsed < 10 ? (10 - elapsed) * 300 : 0;
        // Two floors in the specified-side partial-fill allocation can lose at most two wei.
        assertApproxEqAbs(hook.antiSnipePending(), magnitude * rate / 10_000, 2);
        assertApproxEqAbs(hook.pending(), magnitude / 200, 2);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, params.sqrtPriceLimitX96);
        _assertSettled();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookDifferentialPairFirstTest is HookDifferentialBase {
    function setUp() public {
        _prepare(true);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookDifferentialPairSecondTest is HookDifferentialBase {
    function setUp() public {
        _prepare(false);
    }
}
