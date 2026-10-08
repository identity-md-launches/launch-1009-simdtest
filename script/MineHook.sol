// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../src/HookFlags.sol";

/// @notice Pure salt search. Use the launch factory's actual CREATE2 deployer and exact init-code hash.
/// @dev This helper does not deploy or broadcast; the manifest points directly to SIMDTESTHook.
library MineHook {
    error SaltNotFound();

    function find(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (HookFlags.matches(predicted, HookFlags.SIMDTEST)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
