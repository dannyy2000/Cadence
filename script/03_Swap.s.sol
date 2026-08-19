// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BaseScript} from "./base/BaseScript.sol";

contract SwapScript is BaseScript {
    function run() external {
        vm.startBroadcast();
        ensureCurrencies();
        vm.stopBroadcast();

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hookContract // This must match the pool
        });
        bytes memory hookData = new bytes(0);

        vm.startBroadcast();

        // We'll approve both, just for testing.
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);

        // AMOUNT_IN/ZERO_FOR_ONE let a caller trigger either an instant below-threshold swap
        // or a queued above-threshold one without editing this file.
        uint256 amountIn = vm.envOr("AMOUNT_IN", uint256(1e18));
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);

        // Execute swap
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0, // Very bad, but we want to allow for unlimited price impact
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: hookData,
            receiver: deployerAddress,
            // A short buffer here is flaky: this deadline is computed during Foundry's
            // simulation pass, but only checked once the transaction is actually mined for
            // real, which can land noticeably later in wall-clock time.
            deadline: block.timestamp + 3600
        });

        vm.stopBroadcast();
    }
}
