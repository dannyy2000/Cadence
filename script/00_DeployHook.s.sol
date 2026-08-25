// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {CadenceHook} from "../src/CadenceHook.sol";

/// @notice Mines the address and deploys the CadenceHook contract
contract DeployHookScript is BaseScript {
    // Example values for a token pair with 18 decimals — tune per deployment.
    uint256 constant BATCH_THRESHOLD = 5e18;
    uint256 constant BATCH_WINDOW_BLOCKS = 10;
    // Gas-safety cap: a batch force-settles at this size or the deadline, whichever comes
    // first. CLVR's selection step is O(n) per order settled, so this bounds worst-case
    // settlement gas regardless of how large a batch is allowed to grow.
    uint256 constant MAX_BATCH_SIZE = 20;

    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(CadenceHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        CadenceHook cadenceHook =
            new CadenceHook{salt: salt}(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
        vm.stopBroadcast();

        require(address(cadenceHook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
