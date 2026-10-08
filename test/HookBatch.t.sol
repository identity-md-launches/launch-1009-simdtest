// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {BatchSwapRouter} from "./helpers/BatchSwapRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HookBatchTest is LaunchFixture {
    using StateLibrary for IPoolManager;
    BatchSwapRouter internal batch;

    function setUp() public {
        _local(true, true);
        batch = new BatchSwapRouter(manager);
        IERC20(PAIR).approve(address(batch), type(uint256).max);
        token.approve(address(batch), type(uint256).max);
    }

    struct Outcome {
        uint256 anti;
        uint256 growth;
        uint256 pairBalance;
        uint256 tokenBalance;
        uint256 feeGrowth0;
        uint256 feeGrowth1;
        uint160 price;
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_NettingAcrossOneUnlockMatchesSeparateSwaps(uint96 raw, uint8 age) public {
        vm.roll(opened + bound(age, 0, 12));
        uint256 amount = bound(raw, 1, 10 ether);
        SwapParams[] memory trades = new SwapParams[](8);
        for (uint256 i; i < trades.length; ++i) {
            trades[i] = _params(i % 4 < 2, i % 2 == 0, amount + i);
        }
        uint256 snapshot = vm.snapshotState();
        BalanceDelta[] memory netted = batch.swap(key, trades);
        Outcome memory expected = _outcome();
        _assertSettled();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i; i < trades.length; ++i) {
            BalanceDelta single = router.swap(key, trades[i]);
            assertEq(BalanceDelta.unwrap(single), BalanceDelta.unwrap(netted[i]));
        }
        assertEq(abi.encode(_outcome()), abi.encode(expected));
        _assertSettled();
    }

    function test_LaterSwapFailureRollsBackAllEarlierSwapsInUnlock() public {
        _checkSwap(true, true, 1 ether, 0);
        Outcome memory before = _outcome();
        uint256 claims = manager.balanceOf(address(hook), uint160(PAIR));
        SwapParams[] memory trades = new SwapParams[](4);
        trades[0] = _params(true, true, 10 ether);
        trades[1] = _params(false, false, 3 ether);
        trades[2] = _params(true, false, 1 ether);
        trades[3] = _params(false, true, 0);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        batch.swap(key, trades);
        assertEq(abi.encode(_outcome()), abi.encode(before));
        assertEq(manager.balanceOf(address(hook), uint160(PAIR)), claims);
        _assertSettled();
        hook.sweep(); // Neither the quote nor a revert may leave the manager or hook locked.
        _assertSettled();
    }

    function _outcome() internal view returns (Outcome memory o) {
        o.anti = hook.antiSnipePending();
        o.growth = hook.pending();
        o.pairBalance = IERC20(PAIR).balanceOf(address(this));
        o.tokenBalance = token.balanceOf(address(this));
        (o.feeGrowth0, o.feeGrowth1) = manager.getFeeGrowthGlobals(key.toId());
        (o.price,,,) = manager.getSlot0(key.toId());
    }
}
