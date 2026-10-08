// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SIMDTESTHook} from "src/SIMDTESTHook.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Opt-in with forge test --fork-url <RPC> --fork-block-number <block> --match-contract MainnetForkTest.
/// No environment reads, RPC dependencies or synthetic mainnet contracts in the default run.
contract MainnetForkTest is LaunchFixture {
    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 1, "mainnet fork required");
        assertGt(MAINNET_MANAGER.code.length, 0, "missing mainnet PoolManager");
        assertGt(PAIR.code.length, 0, "missing mainnet IMD");
        assertEq(IERC20Metadata(PAIR).symbol(), "IMD");
        assertEq(IERC20Metadata(PAIR).decimals(), 18);
        // Funding cheat changes the balance only; real IMD code and real manager stay intact.
        deal(PAIR, address(this), 1e24);
        _deploy(IPoolManager(MAINNET_MANAGER), true);
        _seed(-600, 600, LIQUIDITY);
    }

    function testFork_EarlyAndLateAllSwapModesSweepAndDonate() public {
        for (uint256 elapsed; elapsed <= 10; ++elapsed) {
            _checkSwap(true, true, 1 ether, elapsed);
            _checkSwap(true, false, 1 ether, elapsed);
            _checkSwap(false, true, 1 ether, elapsed);
            _checkSwap(false, false, 1 ether, elapsed);
        }
        uint256 vaultBefore = IERC20Metadata(PAIR).balanceOf(VAULT);
        uint256 anti = hook.antiSnipePending();
        assertEq(hook.sweep(), anti);
        assertEq(IERC20Metadata(PAIR).balanceOf(VAULT), vaultBefore + anti);
        vm.warp(hook.lastBatch() + 3600);
        uint256 pending = hook.pending();
        assertEq(hook.donateBatch(), pending / 2);
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_ForkSwaps(bool buy, bool exactInput, uint96 raw, uint8 elapsed) public {
        _checkSwap(buy, exactInput, bound(raw, 1e8, 10 ether), bound(elapsed, 0, 20));
    }

    function testFork_FailedSwapAndPrematureBatchPreserveRealIMDClaims() public {
        _checkSwap(true, true, 100 ether, 0);
        uint256 anti = hook.antiSnipePending();
        uint256 pending = hook.pending();
        uint256 last = hook.lastBatch();
        uint256 managerBalance = IERC20Metadata(PAIR).balanceOf(address(manager));
        SwapParams memory params = _params(false, false, 10 ether);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.unsettledSwap(key, params);
        assertEq(hook.antiSnipePending(), anti);
        assertEq(hook.pending(), pending);
        assertEq(IERC20Metadata(PAIR).balanceOf(address(manager)), managerBalance);
        _assertSettled();
        vm.warp(last + 3599);
        vm.expectRevert(SIMDTESTHook.BatchTooSoon.selector);
        hook.donateBatch();
        assertEq(hook.lastBatch(), last);
        assertEq(hook.pending(), pending);
        vm.warp(last + 3600);
        assertEq(hook.donateBatch(), pending / 2);
        assertEq(hook.antiSnipePending(), anti);
        _assertSettled();
    }

    function testFork_NoLiquidityFailureDoesNotFreezeSweepOrRetry() public {
        _checkSwap(false, true, 100 ether, 0);
        uint256 anti = hook.antiSnipePending();
        uint256 pending = hook.pending();
        uint256 last = hook.lastBatch();
        router.liquidity(key, ModifyLiquidityParams(-600, 600, -int256(LIQUIDITY), bytes32(0)));
        vm.warp(last + 3600);
        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        hook.donateBatch();
        assertEq(hook.pending(), pending);
        assertEq(hook.lastBatch(), last);
        uint256 vaultBefore = IERC20Metadata(PAIR).balanceOf(VAULT);
        vm.prank(makeAddr("mainnet keeper"));
        assertEq(hook.sweep(), anti);
        assertEq(IERC20Metadata(PAIR).balanceOf(VAULT) - vaultBefore, anti);
        _seed(-600, 600, LIQUIDITY);
        assertEq(hook.donateBatch(), pending / 2);
        BalanceDelta earned = router.liquidity(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
        assertApproxEqAbs(uint256(_pairDelta(earned)), pending / 2, 1);
        _assertSettled();
    }
}
