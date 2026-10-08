// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AccountingHandler is Test {
    SIMDTESTHook public immutable hook;
    PoolRouter public immutable router;
    PoolKey internal key;
    uint256 public totalAnti;
    uint256 public totalGrowth;
    uint256 public totalSwept;
    uint256 public totalDonated;

    constructor(SIMDTESTHook hook_, PoolRouter router_) {
        hook = hook_;
        router = router_;
        key = hook_.poolKey();
        IERC20(hook_.token()).approve(address(router_), type(uint256).max);
        IERC20(hook_.PAIRED_CURRENCY()).approve(address(router_), type(uint256).max);
    }

    function trade(bool buy, bool exactInput, uint96 raw, uint8 advance) public {
        vm.roll(block.number + bound(advance, 0, 2));
        uint256 amount = bound(raw, 1e8, 1 ether);
        bool zeroForOne = buy == hook.pairedIs0();
        uint256 anti = hook.antiSnipePending();
        uint256 growth = hook.pending();
        router.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        totalAnti += hook.antiSnipePending() - anti;
        totalGrowth += hook.pending() - growth;
    }

    function sweep() public {
        totalSwept += hook.sweep();
    }

    function donate(uint16 elapsed) public {
        vm.warp(block.timestamp + bound(elapsed, 0, 7200));
        if (block.timestamp - hook.lastBatch() >= 3600 && hook.pending() >= 2) {
            uint256 before = hook.pending();
            uint256 amount = hook.donateBatch();
            assertLe(amount, before / 2);
            totalDonated += amount;
        }
    }
}

contract AccountingInvariantTest is LaunchFixture {
    AccountingHandler internal handler;

    function setUp() public {
        _local(true, true);
        handler = new AccountingHandler(hook, router);
        token.transfer(address(handler), 100_000 ether);
        IERC20(PAIR).transfer(address(handler), 100_000 ether);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.sweep.selector;
        selectors[2] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_AllFeesConservedAndAllDeltasSettled() public view {
        _assertSettled();
        assertEq(handler.totalAnti(), hook.antiSnipePending() + handler.totalSwept());
        assertEq(handler.totalGrowth(), hook.pending() + handler.totalDonated());
        assertEq(IERC20(PAIR).balanceOf(VAULT), handler.totalSwept());
        assertLe(hook.antiSnipeBps(), 3000);
        assertEq(token.totalSupply(), 1e27);
    }
}
