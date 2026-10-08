// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {MineHook} from "../script/MineHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SIMDTESTHookTest is LaunchFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _local(true, true);
    }

    function test_AllBlocksAndSwapModes() public {
        for (uint256 elapsed; elapsed <= 11; ++elapsed) {
            _checkSwap(true, true, 1 ether, elapsed);
            _checkSwap(true, false, 1 ether, elapsed);
            _checkSwap(false, true, 1 ether, elapsed);
            _checkSwap(false, false, 1 ether, elapsed);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SwapAccounting(bool buy, bool exactInput, uint96 raw, uint8 age) public {
        _checkSwap(buy, exactInput, bound(raw, 1e6, 100 ether), bound(age, 0, 30));
    }

    function test_PermissionsAndInitialization() public view {
        assertTrue(hook.initialized());
        assertEq(hook.openingBlock(), opened);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.SIMDTEST);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
    }

    function test_UnauthorizedCallbacksAndQuote() public {
        SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(false, 1 ether));
        vm.expectRevert(SIMDTESTHook.OnlySelf.selector);
        hook.quotePairDelta(key, params);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(false, 1 ether));
    }

    function test_RejectOtherPoolsAndSecondInitialization() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, PRICE);
        other.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(other, PRICE);
        vm.expectRevert();
        manager.initialize(key, PRICE);
    }

    function test_SweepPermissionlessAndSeparateFromDonation() public {
        _checkSwap(true, true, 100 ether, 0);
        uint256 anti = hook.antiSnipePending();
        uint256 pending = hook.pending();
        uint256 beforeVault = IERC20(PAIR).balanceOf(VAULT);
        vm.prank(makeAddr("keeper"));
        assertEq(hook.sweep(), anti);
        assertEq(IERC20(PAIR).balanceOf(VAULT) - beforeVault, anti);
        assertEq(hook.antiSnipePending(), 0);
        assertEq(hook.pending(), pending);
        assertEq(hook.sweep(), 0);
        _assertSettled();
    }

    function test_DonationTimingHalfAndLPEarnings() public {
        _checkSwap(true, true, 100 ether, 0);
        uint256 pending = hook.pending();
        uint256 anti = hook.antiSnipePending();
        uint256 last = hook.lastBatch();
        vm.warp(last + 3599);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.donateBatch();
        // Collect prior LP fees so the next collect isolates the donation.
        router.liquidity(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
        uint256 beforeManager = IERC20(PAIR).balanceOf(address(manager));
        vm.warp(last + 3600);
        vm.prank(makeAddr("anyone"));
        assertEq(hook.donateBatch(), pending / 2);
        assertEq(hook.pending(), pending - pending / 2);
        assertEq(hook.antiSnipePending(), anti);
        assertEq(hook.lastBatch(), block.timestamp);
        assertEq(IERC20(PAIR).balanceOf(address(manager)), beforeManager);
        BalanceDelta earned = router.liquidity(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
        assertApproxEqAbs(uint256(_pairDelta(earned)), pending / 2, 1);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.donateBatch();
        vm.warp(block.timestamp + 3600);
        uint256 remaining = hook.pending();
        assertEq(hook.donateBatch(), remaining / 2);
        _assertSettled();
    }

    function test_EmptyDonationDoesNotConsumeTimer() public {
        uint256 last = hook.lastBatch();
        vm.warp(last + 3600);
        vm.expectRevert(SIMDTESTHook.NoDonation.selector);
        hook.donateBatch();
        assertEq(hook.lastBatch(), last);
        _checkSwap(true, true, 1 ether, 10);
        hook.donateBatch();
        _assertSettled();
    }

    function test_DonationWithoutLiquidityRollsBack() public {
        _checkSwap(true, true, 1 ether, 10);
        router.liquidity(key, ModifyLiquidityParams(-600, 600, -int256(LIQUIDITY), bytes32(0)));
        uint256 pending = hook.pending();
        uint256 last = hook.lastBatch();
        vm.warp(last + 3600);
        vm.expectRevert();
        hook.donateBatch();
        assertEq(hook.pending(), pending);
        assertEq(hook.lastBatch(), last);
        _assertSettled();
    }

    function test_FailedSweepPreservesClaimsAndDoesNotBlockSwaps() public {
        _checkSwap(true, true, 10 ether, 0);
        uint256 anti = hook.antiSnipePending();
        vm.mockCallRevert(PAIR, abi.encodeWithSelector(IERC20.transfer.selector, VAULT, anti), "blocked transfer");
        vm.expectRevert();
        hook.sweep();
        assertEq(hook.antiSnipePending(), anti);
        _assertSettled();
        _checkSwap(true, false, 1 ether, 1);
        vm.clearMockedCalls();
        hook.sweep();
        _assertSettled();
    }

    function test_QuoteRollsBackPriceAndFeeGrowth() public {
        PoolKey memory control = hook.poolKey();
        control.hooks = IHooks(address(0));
        manager.initialize(control, PRICE);
        router.liquidity(control, ModifyLiquidityParams(-600, 600, int256(LIQUIDITY), bytes32(0)));
        BalanceDelta taxed = router.swap(key, _params(true, true, 10 ether));
        BalanceDelta plain = router.swap(control, _params(true, true, 6.95 ether));
        (uint160 actualPrice,,,) = manager.getSlot0(key.toId());
        (uint160 controlPrice,,,) = manager.getSlot0(control.toId());
        assertEq(actualPrice, controlPrice);
        (uint256 actual0, uint256 actual1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 control0, uint256 control1) = manager.getFeeGrowthGlobals(control.toId());
        assertEq(actual0, control0);
        assertEq(actual1, control1);
        assertEq(taxed.amount1(), plain.amount1());
        assertEq(_pairDelta(taxed) + int256(hook.pending() + hook.antiSnipePending()), _pairDelta(plain));
        _assertSettled();
    }

    function test_InitializationValidatesBeforeBinding() public {
        bytes memory code = abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token)));
        (bytes32 salt,) = MineHook.find(address(this), keccak256(code), 200_000, 200_000);
        SIMDTESTHook fresh = new SIMDTESTHook{salt: salt}(manager, address(token));
        PoolKey memory freshKey = fresh.poolKey();
        PoolKey memory bad = freshKey;
        bad.fee = 3000;
        vm.expectRevert();
        manager.initialize(bad, PRICE);
        assertFalse(fresh.initialized());
        bad.fee = 12500;
        bad.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(bad, PRICE);
        assertFalse(fresh.initialized());
        vm.expectRevert(SIMDTESTHook.NotInitialized.selector);
        fresh.donateBatch();
        // The factory may use an economics-derived price, not necessarily the manifest provenance.
        freshKey = fresh.poolKey();
        vm.prank(makeAddr("launch factory"));
        manager.initialize(freshKey, PRICE + 1);
        assertTrue(fresh.initialized());
        assertEq(fresh.openingBlock(), block.number);
    }

    function test_InvalidPermissionAddressRefusesDeployment() public {
        bytes memory code = abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token)));
        bytes32 salt = keccak256("deliberately unmined");
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
        assertFalse(HookFlags.matches(predicted, HookFlags.SIMDTEST));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SIMDTESTHook{salt: salt}(manager, address(token));
    }

    function test_UnsettledSwapRollsBackFees() public {
        SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.unsettledSwap(key, params);
        assertEq(hook.pending(), 0);
        assertEq(hook.antiSnipePending(), 0);
        _assertSettled();
    }

    function test_TinySwapsRoundDownAndSettle() public {
        for (uint256 i = 1; i < 202; i += 10) {
            router.swap(key, _params(true, true, i));
            router.swap(key, _params(false, true, i));
        }
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PartialFillLargeRequests(bool buy, bool exactInput, uint256 raw, uint8 age) public {
        uint256 amount = bound(raw, 1e24, uint256(type(int256).max) / 2);
        vm.roll(opened + bound(age, 0, 12));
        SwapParams memory params = _params(buy, exactInput, amount);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-60) : int24(60));
        BalanceDelta delta = router.swap(key, params);
        uint256 fees = hook.pending() + hook.antiSnipePending();
        int256 actual = _pairDelta(delta);
        uint256 basis = buy ? uint256(-actual) : uint256(actual) + fees;
        assertLt(basis, 10_000 ether);
        assertApproxEqAbs(hook.antiSnipePending(), basis * hook.antiSnipeBps() / 10_000, 2);
        assertApproxEqAbs(hook.pending(), basis * 50 / 10_000, 2);
        _assertSettled();
    }

    function test_Int256MinimumInputCanPartiallyFill() public {
        SwapParams memory params = _params(true, true, 1);
        params.amountSpecified = type(int256).min;
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-60);
        router.swap(key, params);
        assertGt(hook.pending(), 0);
        _assertSettled();
    }

    function test_UnrepresentableExactOutputRevertsClearly() public {
        SwapParams memory params = _params(false, false, uint256(type(int256).max));
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")),
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SIMDTESTHook.UnrepresentableFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(key, params);
        _assertSettled();
    }

    function test_RuntimeAndCreationSizesNoEscapeOpcodes() public view {
        assertLe(type(SIMDTESTHook).creationCode.length + 64, 49_152);
        _scan(address(hook).code);
        _scan(address(token).code);
    }

    function _scan(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}

contract SIMDTESTHookReverseOrderTest is LaunchFixture {
    function setUp() public {
        _local(false, true);
    }

    function test_AllSwapModesWithPairAsCurrency1() public {
        for (uint256 i; i < 12; ++i) {
            _checkSwap(true, true, 1 ether, i);
            _checkSwap(true, false, 1 ether, i);
            _checkSwap(false, true, 1 ether, i);
            _checkSwap(false, false, 1 ether, i);
        }
        hook.sweep();
        vm.warp(hook.lastBatch() + 3600);
        hook.donateBatch();
        _assertSettled();
    }
}

contract SIMDTESTHookFreshManagerTest is LaunchFixture {
    function setUp() public {
        _local(true, false);
    }

    function test_TokenOnlyLiquidityFirstBuyWithoutManagerIMD() public {
        // Below spot: all currency1 (SIMDTEST). First buy moves downward into the position.
        _seed(-600, -60, LIQUIDITY);
        assertEq(IERC20(PAIR).balanceOf(address(manager)), 0);
        _checkSwap(true, true, 100 ether, 0);
        hook.sweep();
        vm.warp(hook.lastBatch() + 3600);
        hook.donateBatch();
        _assertSettled();
    }

    function test_EmptyPoolSwapDoesNotAccrueFees() public {
        router.swap(key, _params(true, true, 100 ether));
        assertEq(hook.pending(), 0);
        assertEq(hook.antiSnipePending(), 0);
        _assertSettled();
    }
}
