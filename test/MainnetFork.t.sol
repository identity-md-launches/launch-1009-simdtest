// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
}
