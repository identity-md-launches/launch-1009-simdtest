// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

abstract contract FeeBasisChecks is LaunchFixture {
    struct Trade {
        int256 pair;
        int256 tokenAmount;
        uint256 anti;
        uint256 growth;
    }

    function _trade(SwapParams memory params) private returns (Trade memory t) {
        BalanceDelta delta = router.swap(key, params);
        t.pair = _pairDelta(delta);
        t.tokenAmount = hook.pairedIs0() ? int256(delta.amount1()) : int256(delta.amount0());
        t.anti = hook.antiSnipePending();
        t.growth = hook.pending();
        uint256 gross = t.pair < 0 ? uint256(-t.pair) : uint256(t.pair) + t.anti + t.growth;
        assertApproxEqAbs(t.anti, gross * hook.antiSnipeBps() / 10_000, 2);
        assertApproxEqAbs(t.growth, gross * 50 / 10_000, 2);
        _assertSettled();
    }

    function _compare(bool buy, uint256 amount, uint256 age, bool priceLimited) internal {
        vm.roll(opened + age);
        uint256 snapshot = vm.snapshotState();
        SwapParams memory params = _params(buy, true, amount);
        if (priceLimited) {
            params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-60) : int24(60));
        }
        Trade memory exactInput = _trade(params);
        if (!priceLimited && buy && age == 0) {
            assertEq(exactInput.anti, amount * 3000 / 10_000);
            assertEq(exactInput.growth, amount * 50 / 10_000);
        }
        assertTrue(vm.revertToState(snapshot));
        // Ask for the same received asset from identical state, rather than comparing nominal requests.
        params.amountSpecified = buy ? exactInput.tokenAmount : exactInput.pair;
        assertGt(params.amountSpecified, 0);
        Trade memory exactOutput = _trade(params);
        assertApproxEqAbs(exactOutput.pair, exactInput.pair, 8, "mode changes IMD settlement");
        assertApproxEqAbs(exactOutput.tokenAmount, exactInput.tokenAmount, 8, "mode changes token settlement");
        assertApproxEqAbs(exactOutput.anti, exactInput.anti, 4, "mode changes vault fee");
        assertApproxEqAbs(exactOutput.growth, exactInput.growth, 4, "mode changes growth fee");
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function test_EquivalentTradesAtEveryFeeRate() public {
        for (uint256 age; age <= 11; ++age) {
            _compare(true, 100 ether, age, false);
            _compare(false, 100 ether, age, false);
        }
    }

    function test_EquivalentTradesAtPriceLimit() public {
        for (uint256 age; age <= 10; ++age) {
            _compare(true, 1e25, age, true);
            _compare(false, 1e25, age, true);
        }
    }

    function _fuzzEquivalentTrades(bool buy, uint96 raw, uint8 age) internal {
        _compare(buy, bound(raw, 1e6, 100 ether), bound(age, 0, 12), false);
    }
}

contract FeeBasisPair0Test is FeeBasisChecks {
    function setUp() public {
        _local(true, true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EquivalentTrades(bool buy, uint96 raw, uint8 age) public {
        _fuzzEquivalentTrades(buy, raw, age);
    }
}

contract FeeBasisPair1Test is FeeBasisChecks {
    function setUp() public {
        _local(false, true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EquivalentTrades(bool buy, uint96 raw, uint8 age) public {
        _fuzzEquivalentTrades(buy, raw, age);
    }
}
