// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Characterizes the requested current-in-range-LP donation, including its JIT limitation.
/// These tests do not assert protection for LPs who supplied liquidity during fee accrual.
contract DonationRecipientsTest is LaunchFixture {
    function setUp() public {
        _local(true, true);
    }

    function _capture(bool soleLP) private {
        _checkSwap(true, true, 1000 ether, 10);
        uint256 donation = hook.pending() / 2;
        uint256 last = hook.lastBatch();
        // Isolate the donation from the seed position's swap fees.
        router.liquidity(key, ModifyLiquidityParams(-600, 600, soleLP ? -int256(LIQUIDITY) : int256(0), bytes32(0)));
        vm.warp(last + 3600);
        if (soleLP) {
            vm.expectRevert(bytes4(keccak256("NoLiquidityToReceiveFees()")));
            hook.donateBatch();
            assertEq(hook.pending(), donation * 2);
            assertEq(hook.lastBatch(), last);
        }

        address newcomer = makeAddr("new LP");
        token.transfer(newcomer, 1e25);
        IERC20(PAIR).transfer(newcomer, 1e25);
        uint256 pairBefore = IERC20(PAIR).balanceOf(newcomer);
        uint256 tokenBefore = token.balanceOf(newcomer);
        uint256 added = soleLP ? 1e6 : LIQUIDITY * 1000;
        vm.startPrank(newcomer);
        token.approve(address(router), type(uint256).max);
        IERC20(PAIR).approve(address(router), type(uint256).max);
        router.liquidity(key, ModifyLiquidityParams(-60, 60, int256(added), bytes32(0)));
        assertEq(hook.donateBatch(), donation);
        router.liquidity(key, ModifyLiquidityParams(-60, 60, -int256(added), bytes32(0)));
        vm.stopPrank();

        uint256 received = IERC20(PAIR).balanceOf(newcomer) - pairBefore;
        assertApproxEqAbs(received, soleLP ? donation : donation * 1000 / 1001, 2);
        assertApproxEqAbs(token.balanceOf(newcomer), tokenBefore, 2);
        if (!soleLP) {
            BalanceDelta seedEarned = router.liquidity(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
            assertApproxEqAbs(uint256(_pairDelta(seedEarned)), donation / 1001, 1);
        }
        _assertSettled();
    }

    function test_NewInRangePositionReceivesItsProportionalDonation() public {
        _capture(false);
    }

    function test_OnlyInRangePositionReceivesEntireDonation() public {
        _capture(true);
    }
}
