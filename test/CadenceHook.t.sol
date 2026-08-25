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

    function testSettlement_PrimaryTrigger_PaysOutBeneficiary() public {
        address beneficiary = makeAddr("beneficiary");
        uint256 amountIn = 10e18;

        // Queue a large order. hookData carries the real beneficiary, since `sender` here
        // would just be the router.
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(beneficiary),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        assertEq(currency1.balanceOf(beneficiary), 0, "should not be paid before settlement");

        vm.roll(hook.batchDeadline(poolId));

        // Any subsequent swap - even a tiny, unrelated one - settles the overdue batch as a
        // side effect before its own trade is processed.
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.queueLength(poolId), 0, "queue should be cleared after settlement");
        assertEq(hook.batchDeadline(poolId), 0, "deadline should reset after settlement");
        assertGt(currency1.balanceOf(beneficiary), 0, "beneficiary should have been paid");
    }

    function testSettlement_FallbackTrigger_AnyoneCanCallAfterDeadline() public {
        address beneficiary = makeAddr("beneficiary");
        address rando = makeAddr("rando");
        uint256 amountIn = 10e18;

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(beneficiary),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.roll(hook.batchDeadline(poolId));

        // A completely uninvolved address can force settlement once the deadline has passed -
        // the fallback path that bounds worst-case wait time on a quiet pool.
        vm.prank(rando);
        hook.settle(poolKey);

        assertEq(hook.queueLength(poolId), 0);
        assertEq(hook.batchDeadline(poolId), 0);
        assertGt(currency1.balanceOf(beneficiary), 0);
    }

    function testSettle_RevertsBeforeDeadline() public {
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.expectRevert(CadenceHook.BatchNotDue.selector);
        hook.settle(poolKey);
    }

    function testSettlement_OpposingOrders_BothBeneficiariesPaid() public {
        address trader0for1 = makeAddr("trader0for1");
        address trader1for0 = makeAddr("trader1for0");
        uint256 amountIn = 10e18;

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(trader0for1),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.roll(block.number + 3);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: abi.encode(trader1for0),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.roll(hook.batchDeadline(poolId));
        hook.settle(poolKey);

        assertGt(currency1.balanceOf(trader0for1), 0, "zeroForOne trader should receive currency1");
        assertGt(currency0.balanceOf(trader1for0), 0, "oneForZero trader should receive currency0");
        assertEq(hook.queueLength(poolId), 0);
    }

    // ---------------------------------------------------------------------
    // Fuzz tests
    // ---------------------------------------------------------------------

    function testFuzz_ThresholdBoundary(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 50e18);

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(int256(swapDelta.amount0()), -int256(amountIn), "input always fully debited either way");

        if (amountIn < BATCH_THRESHOLD) {
            assertGt(swapDelta.amount1(), 0, "below threshold must execute instantly");
            assertEq(hook.queueLength(poolId), 0, "below threshold must never touch the queue");
        } else {
            assertEq(swapDelta.amount1(), 0, "above threshold must not pay out yet");
            assertEq(hook.queueLength(poolId), 1, "above threshold must join the queue");
            assertEq(hook.queuedOrder(poolId, 0).amountIn, amountIn);
        }
    }

    function testFuzz_DeadlineSetOnceAndUnchangedByLaterOrders(uint256 firstAmount, uint256 secondAmount, uint256 blocksBeforeSecond)
        public
    {
        firstAmount = bound(firstAmount, BATCH_THRESHOLD, 50e18);
        secondAmount = bound(secondAmount, BATCH_THRESHOLD, 50e18);
        blocksBeforeSecond = bound(blocksBeforeSecond, 0, BATCH_WINDOW_BLOCKS - 1);

        swapRouter.swapExactTokensForTokens({
            amountIn: firstAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 expectedDeadline = block.number + BATCH_WINDOW_BLOCKS;
        assertEq(hook.batchDeadline(poolId), expectedDeadline);

        vm.roll(block.number + blocksBeforeSecond);

        swapRouter.swapExactTokensForTokens({
            amountIn: secondAmount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.batchDeadline(poolId), expectedDeadline, "deadline must not move once a batch is open");
        assertEq(hook.queueLength(poolId), 2);
    }

    function testFuzz_MultipleOrdersAccumulateInQueue(uint8 rawCount) public {
        uint256 count = bound(rawCount, 1, 8);
        uint256 amountIn = 10e18;

        for (uint256 i = 0; i < count; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: amountIn,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: abi.encode(makeAddr(string.concat("fuzzTrader", vm.toString(i)))),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        assertEq(hook.queueLength(poolId), count);
    }

    function testFuzz_Settlement_PaysBeneficiaryRegardlessOfOvershoot(uint256 amountIn, uint256 overshootBlocks)
        public
    {
        amountIn = bound(amountIn, BATCH_THRESHOLD, 50e18);
        overshootBlocks = bound(overshootBlocks, 0, 500);

        address beneficiary = makeAddr("fuzzBeneficiary");

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(beneficiary),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Settlement must work whether it's triggered right at the deadline or long after -
        // an overdue batch on a quiet pool is exactly the case the fallback trigger exists for.
        vm.roll(hook.batchDeadline(poolId) + overshootBlocks);
        hook.settle(poolKey);

        assertEq(hook.queueLength(poolId), 0);
        assertEq(hook.batchDeadline(poolId), 0);
        assertGt(currency1.balanceOf(beneficiary), 0);
    }

    function testFuzz_OpposingOrders_BothPaidRegardlessOfAmounts(uint256 amount0In, uint256 amount1In) public {
        amount0In = bound(amount0In, BATCH_THRESHOLD, 50e18);
        amount1In = bound(amount1In, BATCH_THRESHOLD, 50e18);

        address trader0 = makeAddr("fuzzTrader0");
        address trader1 = makeAddr("fuzzTrader1");

        swapRouter.swapExactTokensForTokens({
            amountIn: amount0In,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(trader0),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        swapRouter.swapExactTokensForTokens({
            amountIn: amount1In,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: abi.encode(trader1),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.roll(hook.batchDeadline(poolId));
        hook.settle(poolKey);

        assertGt(currency1.balanceOf(trader0), 0, "zeroForOne trader should receive currency1");
        assertGt(currency0.balanceOf(trader1), 0, "oneForZero trader should receive currency0");
        assertEq(hook.queueLength(poolId), 0);
    }

    /// @dev Verifies CLVR actually reorders trades rather than replaying arrival order, using
    /// the exact worked example from the design conversation: a 100/100 pool (p0 = 1) with
    /// orders {A: sell 5, B: sell 20, C: buy 10, D: buy 3}, submitted in arrival order
    /// A, B, C, D. Hand-derivation (checked step by step against the paper's deviation
    /// metric): D lands closest to p0 first (smallest trade against an undisturbed pool),
    /// then A, then C, then B is forced last. Expected order: D, A, C, B.
    function _deployClvrTestPool() private returns (CadenceHook clvrHook, PoolKey memory clvrPoolKey) {
        (Currency clvrCurrency0, Currency clvrCurrency1) = deployCurrencyPair();

        address flags2 =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x9999 << 144));
        bytes memory constructorArgs2 = abi.encode(poolManager, uint256(1e18), BATCH_WINDOW_BLOCKS);
        deployCodeTo("CadenceHook.sol:CadenceHook", constructorArgs2, flags2);
        clvrHook = CadenceHook(flags2);

        // fee = 0, matching the paper's frictionless simplification used in the hand-derivation.
        clvrPoolKey = PoolKey(clvrCurrency0, clvrCurrency1, 0, 60, IHooks(clvrHook));
        poolManager.initialize(clvrPoolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(clvrPoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(clvrPoolKey.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            100e18
        );
        positionManager.mint(
            clvrPoolKey,
            tickLower,
            tickUpper,
            100e18,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testCLVR_ExecutesInDeviationMinimizingOrder() public {
        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();

        address traderA = makeAddr("traderA_sell5");
        address traderB = makeAddr("traderB_sell20");
        address traderC = makeAddr("traderC_buy10");
        address traderD = makeAddr("traderD_buy3");

        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(traderA),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: 20e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(traderB),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: clvrPoolKey,
            hookData: abi.encode(traderC),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: 3e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: clvrPoolKey,
            hookData: abi.encode(traderD),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(clvrHook.queueLength(clvrPoolId), 4);

        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traderD, false, 3e18, 0);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traderA, true, 5e18, 1);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traderC, false, 10e18, 2);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traderB, true, 20e18, 3);

        vm.roll(clvrHook.batchDeadline(clvrPoolId));
        clvrHook.settle(clvrPoolKey);

        assertEq(clvrHook.queueLength(clvrPoolId), 0);
    }
}
