// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only router; deliberately settles inputs after swap callbacks finish.
contract PoolRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function unsettledSwap(PoolKey memory key, SwapParams memory params) external {
        manager.unlock(abi.encode(uint8(2), msg.sender, key, abi.encode(params)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 op, address payer, PoolKey memory key, bytes memory args) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (op == 1) (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        else delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        if (op != 2) {
            _settle(key.currency0, delta.amount0(), payer);
            _settle(key.currency1, delta.amount1(), payer);
        }
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount, address payer) private {
        if (amount < 0) {
            uint256 owed = uint256(-int256(amount));
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), owed);
            require(manager.settle() == owed, "incorrect settlement");
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(int256(amount)));
        }
    }
}
