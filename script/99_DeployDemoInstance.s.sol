// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

import {CadenceHook} from "../src/CadenceHook.sol";

/// @notice Deploys a second, demo-only CadenceHook instance and pool, identical to the real
/// production deployment (00_DeployHook.s.sol / 01_CreatePoolAndAddLiquidity.s.sol) in every
/// respect EXCEPT batchWindowBlocks, which is much longer here (60 blocks, ~50-60 real
/// seconds on Unichain Sepolia, vs. 10 blocks / ~8-10 seconds in production).
///
/// Why this exists: the production window is calibrated to be short on purpose (see Fix 1 /
/// "How the threshold value itself is set" in the README) - but that makes manually clicking
/// through two separate wallet-confirmed trades to land in the same batch, on camera, for a
/// demo recording, unreliable for a human to pull off, even with every approval already in
/// place. This instance exists ONLY to make that specific moment recordable. It is not a
/// second "real" deployment, isn't linked anywhere as the canonical one, and reuses the same
/// CTA/CTB test tokens and the same calibrated threshold/max-batch-size - the only thing
/// different is how long the window is open, which does not change what the demo proves.
contract DeployDemoInstanceScript is BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;

    uint256 constant BATCH_THRESHOLD = 35e16; // same calibrated 0.35 tokens as production
    uint256 constant BATCH_WINDOW_BLOCKS = 60; // ~50-60 real seconds, vs. production's ~8-10
    uint256 constant MAX_BATCH_SIZE = 20;

    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant STARTING_PRICE = 2 ** 96;
    uint256 constant TOKEN0_AMOUNT = 100e18;
    uint256 constant TOKEN1_AMOUNT = 100e18;

    function run() public {
        // Reuses the existing CTA/CTB pair via CURRENCY0/CURRENCY1 env vars, same as
        // 01_CreatePoolAndAddLiquidity.s.sol does for the production pool - no need for a
        // third test token pair just for this.
        ensureCurrencies();

        CadenceHook demoHook = _deployDemoHook();
        _createPoolAndSeedLiquidity(demoHook);

        console2.log("Demo instance CadenceHook deployed at:", address(demoHook));
        console2.log("batchWindowBlocks:", BATCH_WINDOW_BLOCKS);
    }

    function _deployDemoHook() private returns (CadenceHook demoHook) {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(CadenceHook).creationCode, constructorArgs);

        vm.startBroadcast();
        demoHook = new CadenceHook{salt: salt}(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
        vm.stopBroadcast();

        require(address(demoHook) == hookAddress, "DeployDemoInstanceScript: Hook Address Mismatch");
    }

    function _createPoolAndSeedLiquidity(CadenceHook demoHook) private {
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: demoHook
        });
        bytes memory hookData = new bytes(0);

        int24 currentTick = TickMath.getTickAtSqrtPrice(STARTING_PRICE);
        int24 tickLower = truncateTickSpacing((currentTick - 750 * TICK_SPACING), TICK_SPACING);
        int24 tickUpper = truncateTickSpacing((currentTick + 750 * TICK_SPACING), TICK_SPACING);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            STARTING_PRICE,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            TOKEN0_AMOUNT,
            TOKEN1_AMOUNT
        );

        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            poolKey, tickLower, tickUpper, liquidity, TOKEN0_AMOUNT + 1, TOKEN1_AMOUNT + 1, deployerAddress, hookData
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encodeWithSelector(positionManager.initializePool.selector, poolKey, STARTING_PRICE, hookData);
        params[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 3600
        );

        vm.startBroadcast();
        tokenApprovals();
        positionManager.multicall(params);
        vm.stopBroadcast();
    }
}
