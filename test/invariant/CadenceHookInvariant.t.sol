// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {CadenceHook} from "../../src/CadenceHook.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {CadenceHookHandler} from "./CadenceHookHandler.sol";

/// @notice Stateful invariant suite: drives long randomized sequences of swaps, block
/// advances, and settlements via CadenceHookHandler, then checks properties that must hold
/// no matter what order those actions happened in. These are properties of the queue/
/// settlement *mechanics* specifically, not of settlement pricing - they hold regardless of
/// which clearing rule computes prices, so they stay valid once CLVR (M2) replaces the
/// current placeholder in _settle.
contract CadenceHookInvariantTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 constant BATCH_THRESHOLD = 5e18;
    uint256 constant BATCH_WINDOW_BLOCKS = 10;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    CadenceHook hook;
    PoolId poolId;

    CadenceHookHandler handler;

    function setUp() public {
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS);
        deployCodeTo("CadenceHook.sol:CadenceHook", constructorArgs, flags);
        hook = CadenceHook(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 1_000_000e18;

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

        handler = new CadenceHookHandler(poolManager, swapRouter, hook, poolKey, currency0, currency1);
        targetContract(address(handler));
    }

    /// @dev A batch deadline exists exactly when there's a non-empty queue, and vice versa -
    /// the two are always set and cleared together in _beforeSwap/_settle.
    function invariant_QueueEmptyIffNoDeadline() public view {
        bool queueEmpty = hook.queueLength(poolId) == 0;
        bool noDeadline = hook.batchDeadline(poolId) == 0;
        assertEq(queueEmpty, noDeadline, "queue emptiness and deadline presence must agree");
    }

    /// @dev The hook must never hold more or less claim-token custody than what's actually
    /// owed to still-queued orders - it can't be insolvent (owes more than it holds) or
    /// leaking (holding idle claims nothing queued needs).
    function invariant_HookHoldsExactlyWhatsQueued() public view {
        assertEq(
            poolManager.balanceOf(address(hook), currency0.toId()),
            handler.ghost_queued0In(),
            "hook's currency0 custody must match what's queued"
        );
        assertEq(
            poolManager.balanceOf(address(hook), currency1.toId()),
            handler.ghost_queued1In(),
            "hook's currency1 custody must match what's queued"
        );
    }
}
