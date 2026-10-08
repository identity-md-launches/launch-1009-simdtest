// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";
import {MineHook} from "../../script/MineHook.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract LaunchFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    address internal constant PAIR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant VAULT = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint160 internal constant PRICE = 79228162514264337593543950336;
    uint256 internal constant LIQUIDITY = 1_000_000 ether;
    IPoolManager internal manager;
    SIMDTEST internal token;
    SIMDTESTHook internal hook;
    PoolRouter internal router;
    PoolKey internal key;
    uint256 internal opened;

    function _deploy(IPoolManager manager_, bool pairedIs0) internal {
        manager = manager_;
        do {
            token = new SIMDTEST();
        } while ((PAIR < address(token)) != pairedIs0);
        bytes memory code = abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token)));
        (bytes32 salt, address predicted) = MineHook.find(address(this), keccak256(code), 0, 200_000);
        hook = new SIMDTESTHook{salt: salt}(manager, address(token));
        assertEq(address(hook), predicted);
        key = hook.poolKey();
        manager.initialize(key, PRICE);
        opened = block.number;
        router = new PoolRouter(manager);
        token.approve(address(router), type(uint256).max);
        IERC20(PAIR).approve(address(router), type(uint256).max);
    }

    function _local(bool pairedIs0, bool seed) internal {
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Identity", "IMD", 1e30), PAIR);
        _deploy(new PoolManager(address(this)), pairedIs0);
        if (seed) _seed(-600, 600, LIQUIDITY);
    }

    function _seed(int24 lower, int24 upper, uint256 liquidity) internal {
        router.liquidity(key, ModifyLiquidityParams(lower, upper, int256(liquidity), bytes32(0)));
    }

    function _params(bool buy, bool exactInput, uint256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = buy == hook.pairedIs0();
        return SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _pairDelta(BalanceDelta delta) internal view returns (int256) {
        return hook.pairedIs0() ? int256(delta.amount0()) : int256(delta.amount1());
    }

    function _assertSettled() internal view {
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(manager.balanceOf(address(hook), uint160(PAIR)), hook.pending() + hook.antiSnipePending());
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(IERC20(PAIR).balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
    }

    struct SwapCheck {
        uint256 antiBefore;
        uint256 growthBefore;
        uint256 pairBefore;
        uint256 tokenBefore;
        uint256 anti;
        uint256 growth;
        int256 pairDelta;
        int256 tokenDelta;
    }

    function _checkSwap(bool buy, bool exactInput, uint256 amount, uint256 elapsed) internal {
        vm.roll(opened + elapsed);
        SwapCheck memory c;
        c.antiBefore = hook.antiSnipePending();
        c.growthBefore = hook.pending();
        c.pairBefore = IERC20(PAIR).balanceOf(address(this));
        c.tokenBefore = token.balanceOf(address(this));
        BalanceDelta delta = router.swap(key, _params(buy, exactInput, amount));
        c.anti = hook.antiSnipePending() - c.antiBefore;
        c.growth = hook.pending() - c.growthBefore;
        c.pairDelta = _pairDelta(delta);
        c.tokenDelta = hook.pairedIs0() ? int256(delta.amount1()) : int256(delta.amount0());
        assertEq(int256(IERC20(PAIR).balanceOf(address(this))) - int256(c.pairBefore), c.pairDelta);
        assertEq(int256(token.balanceOf(address(this))) - int256(c.tokenBefore), c.tokenDelta);
        uint256 basis;
        if (buy == exactInput) {
            basis = amount;
            assertEq(c.pairDelta, buy ? -int256(amount) : int256(amount));
        } else {
            int256 raw = c.pairDelta + int256(c.anti + c.growth);
            basis = uint256(raw < 0 ? -raw : raw);
            assertEq(c.tokenDelta, buy ? int256(amount) : -int256(amount));
        }
        assertEq(c.anti, basis * (elapsed >= 10 ? 0 : (10 - elapsed) * 300) / 10_000);
        assertEq(c.growth, basis * 50 / 10_000);
        assertLt(c.anti + c.growth, basis * 35 / 100 + 1);
        if (buy) {
            assertLt(c.pairDelta, 0);
            assertGt(c.tokenDelta, 0);
        } else {
            assertGt(c.pairDelta, 0);
            assertLt(c.tokenDelta, 0);
        }
        (,,, uint24 fee) = manager.getSlot0(key.toId());
        assertEq(fee, 12_500);
        _assertSettled();
    }
}
