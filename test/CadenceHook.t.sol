// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {CadenceHook} from "../src/CadenceHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract CadenceHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 constant BATCH_THRESHOLD = 5e18;
    uint256 constant BATCH_WINDOW_BLOCKS = 10;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    CadenceHook hook;
    PoolId poolId;

    function setUp() public {
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x5555 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS);
        deployCodeTo("CadenceHook.sol:CadenceHook", constructorArgs, flags);
        hook = CadenceHook(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 1000e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testBelowThreshold_ExecutesInstantly() public {
        uint256 amountIn = 1e18; // below BATCH_THRESHOLD

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Executed normally against the AMM curve: full debit, and real output received.
        assertEq(int256(swapDelta.amount0()), -int256(amountIn));
        assertGt(swapDelta.amount1(), 0);

        // Never touched the batch queue.
        assertEq(hook.queueLength(poolId), 0);
        assertEq(hook.batchDeadline(poolId), 0);
    }

    function testAboveThreshold_JoinsQueueInsteadOfExecuting() public {
        uint256 amountIn = 10e18; // above BATCH_THRESHOLD
        uint256 expectedDeadline = block.number + BATCH_WINDOW_BLOCKS;

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Full input debited from the trader, but zero output — nothing executed against
        // the pool. The trade is sitting in the batch queue instead.
        assertEq(int256(swapDelta.amount0()), -int256(amountIn));
        assertEq(swapDelta.amount1(), 0);

        assertEq(hook.queueLength(poolId), 1);
        assertEq(hook.batchDeadline(poolId), expectedDeadline);

        CadenceHook.QueuedOrder memory order = hook.queuedOrder(poolId, 0);
        assertEq(order.trader, address(swapRouter));
        assertTrue(order.zeroForOne);
        assertEq(order.amountIn, amountIn);
        assertEq(order.blockNumber, block.number);
    }

    function testSecondOrderJoinsSameBatch_DeadlineUnchanged() public {
        uint256 amountIn = 10e18;

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 firstDeadline = hook.batchDeadline(poolId);

        // Still inside the same batch window.
        vm.roll(block.number + 3);
        assertLt(block.number, firstDeadline);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Second order joined the same batch: queue grew, deadline did not move.
        assertEq(hook.queueLength(poolId), 2);
        assertEq(hook.batchDeadline(poolId), firstDeadline);

        CadenceHook.QueuedOrder memory second = hook.queuedOrder(poolId, 1);
        assertFalse(second.zeroForOne);
        assertEq(second.amountIn, amountIn);
    }

    function testExactOutputSwap_NotIntercepted() public {
        // Exact-output swaps (positive amountSpecified) are out of scope for batching and
        // always execute normally, regardless of size.
        BalanceDelta swapDelta = swapRouter.swapTokensForExactTokens({
            amountOut: 10e18,
            amountInMax: type(uint256).max,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(int256(swapDelta.amount1()), int256(10e18));
        assertEq(hook.queueLength(poolId), 0);
    }
}
