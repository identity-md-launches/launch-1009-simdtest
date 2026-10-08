// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {SIMDTESTHook} from "src/SIMDTESTHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The model derives specified-IMD fees from trader budgets and elapsed blocks, never
/// from changes in hook.pending(). All expected failures are checked, not caught and discarded.
contract FeeLifecycleHandler is Test {
    SIMDTESTHook public immutable hook;
    PoolRouter public immutable router;
    PoolKey internal key;
    uint256 public immutable opened;
    uint256 public immutable positionLiquidity;
    uint256 public expectedAnti;
    uint256 public expectedGrowth;
    uint256 public expectedLastBatch;
    uint256 public totalAnti;
    uint256 public totalGrowth;
    uint256 public swept;
    uint256 public donated;
    bool public liquid = true;

    constructor(SIMDTESTHook hook_, PoolRouter router_, uint256 liquidity_) {
        hook = hook_;
        router = router_;
        opened = hook_.openingBlock();
        expectedLastBatch = hook_.lastBatch();
        positionLiquidity = liquidity_;
        key = hook_.poolKey();
        IERC20(hook_.token()).approve(address(router_), type(uint256).max);
        IERC20(hook_.PAIRED_CURRENCY()).approve(address(router_), type(uint256).max);
    }

    function trade(bool buy, uint96 raw) public {
        // Swaps are fully fillable whenever the position exists. This bounds price movement
        // over 64 operations; partial fills and all four modes have separate differential tests.
        if (!liquid) return;
        uint256 amount = bound(raw, 1, 1 ether);
        uint256 age = block.number - opened;
        uint256 antiRate = age < 10 ? (10 - age) * 300 : 0;
        // Buys specify a gross input budget; sells specify the net output after both fees.
        uint256 denominator = buy ? 10_000 : 10_000 - antiRate - 50;
        uint256 anti = amount * antiRate / denominator;
        uint256 growth = amount * 50 / denominator;
        bool zeroForOne = buy == hook.pairedIs0();
        BalanceDelta delta = router.swap(
            key,
            SwapParams(
                zeroForOne,
                buy ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        int256 pair = hook.pairedIs0() ? int256(delta.amount0()) : int256(delta.amount1());
        assertEq(pair, buy ? -int256(amount) : int256(amount));
        expectedAnti += anti;
        expectedGrowth += growth;
        totalAnti += anti;
        totalGrowth += growth;
    }

    function advance(uint8 blocks_, uint16 seconds_) public {
        vm.roll(block.number + bound(blocks_, 0, 3));
        vm.warp(block.timestamp + bound(seconds_, 0, 7200));
    }

    function sweep() public {
        assertEq(hook.sweep(), expectedAnti);
        swept += expectedAnti;
        expectedAnti = 0;
    }

    function donate() public {
        if (block.timestamp - expectedLastBatch < 3600) {
            vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
            hook.donateBatch();
        } else if (expectedGrowth < 2) {
            vm.expectRevert(SIMDTESTHook.NoDonation.selector);
            hook.donateBatch();
        } else if (!liquid) {
            vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
            hook.donateBatch();
        } else {
            uint256 amount = expectedGrowth / 2;
            assertEq(hook.donateBatch(), amount);
            expectedGrowth -= amount;
            donated += amount;
            expectedLastBatch = block.timestamp;
        }
    }

    function toggleLiquidity() public {
        router.liquidity(
            key,
            ModifyLiquidityParams(
                -600, 600, liquid ? -int256(positionLiquidity) : int256(positionLiquidity), bytes32(0)
            )
        );
        liquid = !liquid;
    }

    function failedUnsettledSwap() public {
        if (!liquid) return;
        bool zeroForOne = hook.pairedIs0();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.unsettledSwap(
            key,
            SwapParams(
                zeroForOne, -int256(1 ether), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }
}

contract FeeLifecycleInvariantTest is LaunchFixture {
    FeeLifecycleHandler internal handler;
    uint256 internal pairSupply;
    uint256 internal vaultBefore;

    function setUp() public {
        // Exercise the currency ordering absent from the original invariant handler.
        _local(false, true);
        handler = new FeeLifecycleHandler(hook, router, LIQUIDITY);
        token.transfer(address(handler), 100_000 ether);
        IERC20(PAIR).transfer(address(handler), 100_000 ether);
        pairSupply = IERC20(PAIR).totalSupply();
        vaultBefore = IERC20(PAIR).balanceOf(VAULT);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.sweep.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.toggleLiquidity.selector;
        selectors[5] = handler.failedUnsettledSwap.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function test_ExactOutputFeeModelUsesGrossIMDThroughSweepAndDonation() public {
        // At launch, a 10,000-wei gross pool output delivers 6,950 wei to the seller,
        // reserving 3,000 wei for the vault and 50 wei for liquidity growth.
        handler.trade(false, 6_950);
        assertEq(hook.antiSnipePending(), 3_000);
        assertEq(hook.pending(), 50);
        invariant_FeesMatchIndependentModelAndAssetsAreConserved();
        handler.sweep();
        vm.warp(hook.lastBatch() + 3600);
        handler.donate();
        assertEq(hook.pending(), 25);
        invariant_FeesMatchIndependentModelAndAssetsAreConserved();

        // With anti-snipe expired, the same gross output delivers 9,950 wei.
        vm.roll(opened + 10);
        handler.trade(false, 9_950);
        assertEq(hook.antiSnipePending(), 0);
        assertEq(hook.pending(), 75);
        invariant_FeesMatchIndependentModelAndAssetsAreConserved();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FeesMatchIndependentModelAndAssetsAreConserved() public view {
        assertEq(hook.antiSnipePending(), handler.expectedAnti());
        assertEq(hook.pending(), handler.expectedGrowth());
        assertEq(hook.lastBatch(), handler.expectedLastBatch());
        assertEq(handler.totalAnti(), hook.antiSnipePending() + handler.swept());
        assertEq(handler.totalGrowth(), hook.pending() + handler.donated());
        assertEq(IERC20(PAIR).balanceOf(VAULT) - vaultBefore, handler.swept());
        assertGe(IERC20(PAIR).balanceOf(address(manager)), hook.pending() + hook.antiSnipePending());
        // No deal/mint shortcuts occur after setup. Account for every possible holder.
        assertEq(_balances(IERC20(PAIR)), pairSupply);
        assertEq(_balances(IERC20(address(token))), 1e27);
        assertEq(token.totalSupply(), 1e27);
        _assertSettled();
    }

    function _balances(IERC20 currency) internal view returns (uint256) {
        return currency.balanceOf(address(this)) + currency.balanceOf(address(handler))
            + currency.balanceOf(address(manager)) + currency.balanceOf(address(router))
            + currency.balanceOf(address(hook)) + currency.balanceOf(VAULT);
    }
}
