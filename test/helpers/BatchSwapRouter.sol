// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Net-settles all swaps at the end of one unlock, exercising outstanding transient deltas
/// during the hook's rollback-only nested quote.
contract BatchSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams[] memory params) external returns (BalanceDelta[] memory) {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address payer, PoolKey memory key, SwapParams[] memory params) =
            abi.decode(data, (address, PoolKey, SwapParams[]));
        BalanceDelta[] memory deltas = new BalanceDelta[](params.length);
        for (uint256 i; i < params.length; ++i) {
            deltas[i] = manager.swap(key, params[i], "");
        }
        _settle(key.currency0, payer);
        _settle(key.currency1, payer);
        return abi.encode(deltas);
    }

    function _settle(Currency currency, address payer) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), uint256(-delta));
            require(manager.settle() == uint256(-delta), "settlement mismatch");
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(delta));
        }
    }
}
