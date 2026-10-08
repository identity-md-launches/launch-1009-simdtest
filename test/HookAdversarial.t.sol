// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {SIMDTESTHook} from "src/SIMDTESTHook.sol";
import {MineHook} from "../script/MineHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HookAdversarialTest is LaunchFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _local(true, true);
    }

    function test_ConstructorRejectsMissingCodeAndIdenticalCurrencies() public {
        address noCode = makeAddr("not a contract");
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(IPoolManager(noCode), address(token));
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, noCode);
        vm.expectRevert(SIMDTESTHook.InvalidDeployment.selector);
        new SIMDTESTHook(manager, PAIR);
    }

    function test_FailedInitializationCannotStartClockOrBindWrongPool() public {
        bytes memory code = abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token)));
        (bytes32 salt,) = MineHook.find(address(this), keccak256(code), 200_000, 200_000);
        SIMDTESTHook fresh = new SIMDTESTHook{salt: salt}(manager, address(token));
        PoolKey memory valid = fresh.poolKey();
        for (uint256 i; i < 4; ++i) {
            PoolKey memory bad = fresh.poolKey();
            if (i == 0) bad.fee = 3_000;
            if (i == 1) bad.fee = 0x800000;
            if (i == 2) bad.tickSpacing = 120;
            if (i == 3) bad.currency0 = Currency.wrap(address(0)); // Invalid pool input, never a deployment setting.
            vm.expectRevert(
                _wrapped(address(fresh), IHooks.beforeInitialize.selector, SIMDTESTHook.InvalidPool.selector)
            );
            manager.initialize(bad, PRICE);
            assertFalse(fresh.initialized());
            assertEq(fresh.openingBlock(), 0);
            assertEq(fresh.lastBatch(), 0);
        }
        // The callback runs before PoolManager validates the price. Its writes must also roll back.
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        manager.initialize(valid, 0);
        assertFalse(fresh.initialized());
        assertEq(fresh.antiSnipeBps(), 0);
        assertEq(fresh.sweep(), 0);
        vm.expectRevert(SIMDTESTHook.NotInitialized.selector);
        fresh.donateBatch();

        vm.roll(block.number + 50);
        vm.warp(block.timestamp + 7000);
        vm.prank(makeAddr("factory"));
        manager.initialize(valid, TickMath.getSqrtPriceAtTick(120));
        assertEq(fresh.openingBlock(), block.number);
        assertEq(fresh.lastBatch(), block.timestamp);
        assertEq(fresh.antiSnipeBps(), 3000);
    }

    function test_ZeroSwapAndFailedInputSettlementPreserveAccruedFees() public {
        _checkSwap(true, true, 1 ether, 0);
        uint256 anti = hook.antiSnipePending();
        uint256 growth = hook.pending();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        SwapParams memory params = _params(true, true, 0);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, params);

        // Failure happens after both hook callbacks and the core swap, when the router settles.
        IERC20(PAIR).approve(address(router), 0);
        params = _params(true, true, 10 ether);
        vm.expectRevert();
        router.swap(key, params);
        assertEq(hook.antiSnipePending(), anti);
        assertEq(hook.pending(), growth);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, price);
        _assertSettled();
        IERC20(PAIR).approve(address(router), type(uint256).max);
        _checkSwap(true, true, 10 ether, 0);
    }

    function test_OddDonationAndOneWeiDustDoNotConsumeAnEmptyBatch() public {
        _checkSwap(true, true, 600, 10); // Three wei of growth fees.
        uint256 last = hook.lastBatch();
        assertEq(hook.pending(), 3);
        vm.warp(last + 3600);
        assertEq(hook.donateBatch(), 1);
        assertEq(hook.pending(), 2);
        vm.warp(last + 7200);
        assertEq(hook.donateBatch(), 1);
        assertEq(hook.pending(), 1);
        uint256 successful = hook.lastBatch();
        vm.warp(last + 10800);
        vm.expectRevert(SIMDTESTHook.NoDonation.selector);
        hook.donateBatch();
        assertEq(hook.lastBatch(), successful);
        assertEq(hook.pending(), 1);
        _checkSwap(true, true, 200, 10);
        assertEq(hook.donateBatch(), 1);
        assertEq(hook.pending(), 1);
        _assertSettled();
    }

    function test_DonationFailureCanBeRetriedAfterLiquidityReturns() public {
        _checkSwap(true, true, 10 ether, 0);
        router.liquidity(key, ModifyLiquidityParams(-600, 600, -int256(LIQUIDITY), bytes32(0)));
        uint256 pending = hook.pending();
        uint256 last = hook.lastBatch();
        uint256 claims = manager.balanceOf(address(hook), uint160(PAIR));
        vm.warp(last + 3600);
        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        hook.donateBatch();
        assertEq(hook.lastBatch(), last);
        assertEq(hook.pending(), pending);
        assertEq(manager.balanceOf(address(hook), uint160(PAIR)), claims);
        _seed(-600, 600, LIQUIDITY);
        assertEq(hook.donateBatch(), pending / 2);
        assertEq(hook.lastBatch(), last + 3600);
        hook.sweep();
        _assertSettled();
    }

    function test_DonationRewardsOnlyInRangeLiquidityWithoutMintingAPosition() public {
        _seed(1200, 1800, LIQUIDITY);
        _checkSwap(true, true, 100 ether, 0);
        router.liquidity(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
        uint128 liquidity = manager.getLiquidity(key.toId());
        uint256 beforeBalance = IERC20(PAIR).balanceOf(address(manager));
        uint256 amount = hook.pending() / 2;
        vm.warp(hook.lastBatch() + 3600);
        hook.donateBatch();
        assertEq(manager.getLiquidity(key.toId()), liquidity);
        assertEq(IERC20(PAIR).balanceOf(address(manager)), beforeBalance);
        BalanceDelta outside = router.liquidity(key, ModifyLiquidityParams(1200, 1800, 0, bytes32(0)));
        assertEq(BalanceDelta.unwrap(outside), 0);
        BalanceDelta inside = router.liquidity(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
        assertApproxEqAbs(uint256(_pairDelta(inside)), amount, 1);
        assertEq(inside.amount1(), 0, "only IMD can be donated");
        _assertSettled();
    }

    function test_SweepAndDonationEventsIdentifyCallerAndExactAmount() public {
        _checkSwap(true, true, 100 ether, 0);
        uint256 anti = hook.antiSnipePending();
        uint256 growth = hook.pending();
        address keeper = makeAddr("unprivileged keeper");
        vm.expectEmit(true, false, false, true, address(hook));
        emit SIMDTESTHook.Swept(keeper, anti);
        vm.prank(keeper);
        hook.sweep();
        vm.warp(hook.lastBatch() + 3600);
        vm.expectEmit(true, false, false, true, address(hook));
        emit SIMDTESTHook.Donated(keeper, growth / 2, block.timestamp);
        vm.prank(keeper);
        hook.donateBatch();
        assertEq(IERC20(PAIR).balanceOf(keeper), 0);
        _assertSettled();
    }

    function test_NoAdminFeeOrClaimApprovalEntrypoints() public {
        _checkSwap(true, true, 1 ether, 0);
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeWithSignature("transferOwnership(address)", address(this));
        calls[1] = abi.encodeWithSignature("upgradeTo(address)", address(token));
        calls[2] = abi.encodeWithSignature("setFees(uint256,uint256)", 0, 0);
        calls[3] = abi.encodeWithSignature("setFee(uint256)", 0);
        calls[4] = abi.encodeWithSignature("setVault(address)", address(this));
        calls[5] = abi.encodeWithSignature("setPoolManager(address)", address(this));
        calls[6] = abi.encodeWithSignature("setOperator(address,bool)", address(this), true);
        calls[7] = abi.encodeWithSignature("approve(address,uint256,uint256)", address(this), uint160(PAIR), 1);
        calls[8] = abi.encodeWithSignature("pause()");
        calls[9] = abi.encodeWithSignature("owner()");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok, "unexpected mutable or administrative surface");
        }
        vm.prank(address(hook));
        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        manager.updateDynamicLPFee(key, 0);
        _assertSettled();
    }

    function _wrapped(address target, bytes4 callback, bytes4 reason) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")),
            target,
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
