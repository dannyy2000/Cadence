// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {MaliciousReentrantToken} from "./utils/MaliciousReentrantToken.sol";
import {BlacklistingToken} from "./utils/BlacklistingToken.sol";
import {SettleReentrantToken, ISettleCallable} from "./utils/SettleReentrantToken.sol";

import {CadenceHook} from "../src/CadenceHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract CadenceHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 constant BATCH_THRESHOLD = 5e18;
    uint256 constant BATCH_WINDOW_BLOCKS = 10;
    uint256 constant MAX_BATCH_SIZE = 20;

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
        bytes memory constructorArgs = abi.encode(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
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

    function testOrderSplitting_CumulativeVolumeGetsSweptIntoQueue() public {
        uint256 pieceAmount = 2e18; // below BATCH_THRESHOLD (5e18) on its own

        // First two pieces stay under the cumulative threshold (2e18, then 4e18) - both
        // execute instantly, exactly like any ordinary small trade.
        for (uint256 i = 0; i < 2; i++) {
            BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
                amountIn: pieceAmount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
            assertGt(swapDelta.amount1(), 0, "piece under cumulative threshold executes instantly");
        }
        assertEq(hook.queueLength(poolId), 0);

        // Third piece takes cumulative volume to 6e18, crossing the 5e18 threshold - this
        // piece (despite being only 2e18 on its own) gets swept into the queue instead.
        BalanceDelta thirdSwapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: pieceAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(thirdSwapDelta.amount1(), 0, "crossing piece must not execute instantly");
        assertEq(hook.queueLength(poolId), 1, "crossing piece must be queued");
        assertEq(hook.queuedOrder(poolId, 0).amountIn, pieceAmount);
    }

    function testOrderSplitting_WindowExpiryResetsCumulativeTracking() public {
        uint256 pieceAmount = 4e18; // below BATCH_THRESHOLD (5e18), but only barely

        swapRouter.swapExactTokensForTokens({
            amountIn: pieceAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Past the window - the tracked cumulative volume should have expired rather than
        // carrying forward indefinitely.
        vm.roll(block.number + BATCH_WINDOW_BLOCKS + 1);

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: pieceAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // 4e18 + 4e18 = 8e18 would have crossed the threshold if it carried forward - it
        // executing instantly proves the window reset instead.
        assertGt(swapDelta.amount1(), 0, "expired window must not carry cumulative volume forward");
        assertEq(hook.queueLength(poolId), 0);
    }

    function testOrderSplitting_DirectionsTrackedSeparately() public {
        uint256 pieceAmount = 4e18;

        swapRouter.swapExactTokensForTokens({
            amountIn: pieceAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Opposite direction: 4e18 zeroForOne cumulative volume must not count toward this
        // trade's oneForZero cumulative total.
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: pieceAmount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertGt(swapDelta.amount0(), 0, "opposite direction must not inherit the other direction's cumulative volume");
        assertEq(hook.queueLength(poolId), 0);
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

    function testMaxBatchSize_ForceSettlesBeforeDeadline() public {
        uint256 amountIn = 10e18;
        address[] memory beneficiaries = new address[](MAX_BATCH_SIZE);

        // Submit MAX_BATCH_SIZE - 1 orders, well before the deadline - queue should just
        // keep growing, no settlement yet.
        for (uint256 i = 0; i < MAX_BATCH_SIZE - 1; i++) {
            beneficiaries[i] = makeAddr(string.concat("capTrader", vm.toString(i)));
            swapRouter.swapExactTokensForTokens({
                amountIn: amountIn,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: abi.encode(beneficiaries[i]),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }
        assertEq(hook.queueLength(poolId), MAX_BATCH_SIZE - 1);
        assertLt(block.number, hook.batchDeadline(poolId), "still well before the deadline");

        // The MAX_BATCH_SIZE-th order pushes the queue to its cap - settlement must fire
        // immediately as a side effect of this same call, not wait for the deadline.
        beneficiaries[MAX_BATCH_SIZE - 1] = makeAddr("capTraderLast");
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(beneficiaries[MAX_BATCH_SIZE - 1]),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.queueLength(poolId), 0, "batch must force-settle at the size cap");
        assertEq(hook.batchDeadline(poolId), 0);

        for (uint256 i = 0; i < MAX_BATCH_SIZE; i++) {
            bool paidInCurrency1 = i % 2 == 0 || i == MAX_BATCH_SIZE - 1;
            if (paidInCurrency1) {
                assertGt(currency1.balanceOf(beneficiaries[i]), 0);
            } else {
                assertGt(currency0.balanceOf(beneficiaries[i]), 0);
            }
        }
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
        bytes memory constructorArgs2 = abi.encode(poolManager, uint256(1e18), BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
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

    /// @dev Proves the reentrancy guard actually blocks an attempted swap mid-settlement,
    /// rather than just asserting the guard code looks right. Uses a token whose `transfer`
    /// tries to swap directly against the pool the instant it's invoked - simulating a
    /// nonstandard ERC20 with a transfer hook (the same real-world category as ERC777) - as
    /// the payout currency for one queued order, so the attack fires from inside CadenceHook's
    /// own settlement loop.
    function _deployReentrancyTestPool()
        private
        returns (CadenceHook reHook, PoolKey memory rePoolKey, MockERC20 goodToken, MaliciousReentrantToken badToken, bool badIsCurrency1)
    {
        goodToken = new MockERC20("Good Token", "GOOD", 18);
        badToken = new MaliciousReentrantToken("Bad Token", "BAD", 18);

        goodToken.mint(address(this), 10_000_000 ether);
        badToken.mint(address(this), 10_000_000 ether);

        goodToken.approve(address(permit2), type(uint256).max);
        goodToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(goodToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(goodToken), address(poolManager), type(uint160).max, type(uint48).max);

        badToken.approve(address(permit2), type(uint256).max);
        badToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(badToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(badToken), address(poolManager), type(uint160).max, type(uint48).max);

        (Currency reCurrency0, Currency reCurrency1) = address(goodToken) < address(badToken)
            ? (Currency.wrap(address(goodToken)), Currency.wrap(address(badToken)))
            : (Currency.wrap(address(badToken)), Currency.wrap(address(goodToken)));
        badIsCurrency1 = Currency.unwrap(reCurrency1) == address(badToken);

        address flags3 =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x7777 << 144));
        bytes memory constructorArgs3 = abi.encode(poolManager, uint256(1e18), BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
        deployCodeTo("CadenceHook.sol:CadenceHook", constructorArgs3, flags3);
        reHook = CadenceHook(flags3);

        rePoolKey = PoolKey(reCurrency0, reCurrency1, 3000, 60, IHooks(reHook));
        poolManager.initialize(rePoolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(rePoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(rePoolKey.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            1000e18
        );
        positionManager.mint(
            rePoolKey,
            tickLower,
            tickUpper,
            1000e18,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        badToken.arm(poolManager, rePoolKey);
    }

    function testReentrancy_SwapAttemptedDuringSettlementIsRejected() public {
        (CadenceHook reHook, PoolKey memory rePoolKey, MockERC20 goodToken, MaliciousReentrantToken badToken, bool badIsCurrency1)
        = _deployReentrancyTestPool();
        PoolId rePoolId = rePoolKey.toId();

        address victim = makeAddr("reentrancyVictim");
        address otherTrader = makeAddr("reentrancyOtherTrader");

        // This order's payout currency is the malicious token - settling it is what triggers
        // the reentrancy attempt.
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: badIsCurrency1,
            poolKey: rePoolKey,
            hookData: abi.encode(victim),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // A second, unrelated order in the opposite direction - proves the attack attempt
        // doesn't take down the rest of the batch with it.
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: !badIsCurrency1,
            poolKey: rePoolKey,
            hookData: abi.encode(otherTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.roll(reHook.batchDeadline(rePoolId));
        reHook.settle(rePoolKey);

        assertTrue(badToken.reentryAttempted(), "malicious token should have attempted to reenter");
        assertTrue(badToken.reentryReverted(), "the reentrant swap attempt must have been rejected");

        // Settlement completed normally for everyone despite the attack attempt.
        assertEq(reHook.queueLength(rePoolId), 0);
        assertGt(badToken.balanceOf(victim), 0, "victim should still receive their real payout");
        assertGt(goodToken.balanceOf(otherTrader), 0, "the other queued order should settle normally too");
    }

    function _deployGriefingTestPool()
        private
        returns (CadenceHook grHook, PoolKey memory grPoolKey, MockERC20 goodToken, BlacklistingToken badToken)
    {
        goodToken = new MockERC20("Good Token", "GOOD", 18);
        badToken = new BlacklistingToken("Blacklisting Token", "BLK", 18);

        goodToken.mint(address(this), 10_000_000 ether);
        badToken.mint(address(this), 10_000_000 ether);

        goodToken.approve(address(permit2), type(uint256).max);
        goodToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(goodToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(goodToken), address(poolManager), type(uint160).max, type(uint48).max);

        badToken.approve(address(permit2), type(uint256).max);
        badToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(badToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(badToken), address(poolManager), type(uint160).max, type(uint48).max);

        (Currency grCurrency0, Currency grCurrency1) = address(goodToken) < address(badToken)
            ? (Currency.wrap(address(goodToken)), Currency.wrap(address(badToken)))
            : (Currency.wrap(address(badToken)), Currency.wrap(address(goodToken)));

        address flags4 =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x8888 << 144));
        bytes memory constructorArgs4 = abi.encode(poolManager, uint256(1e18), BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
        deployCodeTo("CadenceHook.sol:CadenceHook", constructorArgs4, flags4);
        grHook = CadenceHook(flags4);

        grPoolKey = PoolKey(grCurrency0, grCurrency1, 3000, 60, IHooks(grHook));
        poolManager.initialize(grPoolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(grPoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(grPoolKey.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            1000e18
        );
        positionManager.mint(
            grPoolKey,
            tickLower,
            tickUpper,
            1000e18,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    /// @dev Proves one order's real execution failing doesn't abort the rest of the batch,
    /// using a realistic, well-documented failure mode: a payout currency (BlacklistingToken,
    /// modeling USDC/USDT-style address blacklisting) that reverts for one specific recipient.
    function testGriefing_OneBadOrderDoesNotRevertTheWholeBatch() public {
        (CadenceHook grHook, PoolKey memory grPoolKey, MockERC20 goodToken, BlacklistingToken badToken) =
            _deployGriefingTestPool();
        PoolId grPoolId = grPoolKey.toId();
        bool badIsCurrency1 = Currency.unwrap(grPoolKey.currency1) == address(badToken);

        address blacklistedTrader = makeAddr("blacklistedTrader");
        address normalTrader = makeAddr("normalTrader");
        badToken.setBlacklisted(blacklistedTrader);

        // This order's payout currency is the blacklisting token, to a recipient that token
        // has blacklisted - its real execution will fail.
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: badIsCurrency1,
            poolKey: grPoolKey,
            hookData: abi.encode(blacklistedTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // A second, unrelated order in the opposite direction - proves it settles normally
        // despite the other order's failure.
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: !badIsCurrency1,
            poolKey: grPoolKey,
            hookData: abi.encode(normalTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // The blacklisted order's direction was chosen (zeroForOne: badIsCurrency1) so its
        // output is always badToken - meaning its input is always goodToken, regardless of
        // which currency slot badToken ended up in.
        uint256 blacklistedTraderInputBalanceBefore = goodToken.balanceOf(blacklistedTrader);

        vm.roll(grHook.batchDeadline(grPoolId));
        grHook.settle(grPoolKey);

        // Settlement completed for everyone - the whole transaction did not revert.
        assertEq(grHook.queueLength(grPoolId), 0);

        // The blacklisted trader never received the blacklisted payout currency...
        assertEq(badToken.balanceOf(blacklistedTrader), 0, "blacklisted trader must not receive the payout");
        // ...but got their original input currency (goodToken) refunded instead of losing it.
        assertGt(
            goodToken.balanceOf(blacklistedTrader),
            blacklistedTraderInputBalanceBefore,
            "blacklisted trader should be refunded their original input"
        );

        // The other, unaffected order settled completely normally.
        assertGt(goodToken.balanceOf(normalTrader), 0, "unaffected order must still settle normally");
    }

    function testFuzz_RefundExactlyMatchesOriginalInput(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e18, 50e18);

        (CadenceHook grHook, PoolKey memory grPoolKey, MockERC20 goodToken, BlacklistingToken badToken) =
            _deployGriefingTestPool();
        PoolId grPoolId = grPoolKey.toId();
        bool badIsCurrency1 = Currency.unwrap(grPoolKey.currency1) == address(badToken);

        address blacklistedTrader = makeAddr("fuzzBlacklistedTrader");
        badToken.setBlacklisted(blacklistedTrader);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: badIsCurrency1,
            poolKey: grPoolKey,
            hookData: abi.encode(blacklistedTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.roll(grHook.batchDeadline(grPoolId));
        grHook.settle(grPoolKey);

        assertEq(goodToken.balanceOf(blacklistedTrader), amountIn, "refund must exactly match original input");
    }

    // ---------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------

    function test_UnlockCallback_RevertsIfNotCalledByPoolManager() public {
        vm.expectRevert();
        hook.unlockCallback(abi.encode(poolKey));
    }

    function test_ExecuteOrder_RevertsIfNotCalledBySelf() public {
        CadenceHook.QueuedOrder memory fakeOrder =
            CadenceHook.QueuedOrder({trader: address(this), zeroForOne: true, amountIn: 1e18, blockNumber: block.number});
        vm.expectRevert(CadenceHook.OnlySelf.selector);
        hook._executeOrder(poolKey, fakeOrder);
    }

    function testConstructor_RevertsIfBatchWindowBlocksIsZero() public {
        address flags5 =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0xAAAA << 144));
        bytes memory badArgs = abi.encode(poolManager, BATCH_THRESHOLD, uint256(0), MAX_BATCH_SIZE);
        vm.expectRevert(bytes("batchWindowBlocks must be > 0"));
        deployCodeTo("CadenceHook.sol:CadenceHook", badArgs, flags5);
    }

    function testConstructor_RevertsIfMaxBatchSizeIsZero() public {
        address flags6 =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0xBBBB << 144));
        bytes memory badArgs = abi.encode(poolManager, BATCH_THRESHOLD, BATCH_WINDOW_BLOCKS, uint256(0));
        vm.expectRevert(bytes("maxBatchSize must be > 0"));
        deployCodeTo("CadenceHook.sol:CadenceHook", badArgs, flags6);
    }

    // ---------------------------------------------------------------------
    // View function edge cases
    // ---------------------------------------------------------------------

    function testBlocksUntilDeadline_ZeroWhenNoBatchOpen() public view {
        assertEq(hook.blocksUntilDeadline(poolId), 0);
    }

    function testBlocksUntilDeadline_CorrectCountdown() public {
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        assertEq(hook.blocksUntilDeadline(poolId), BATCH_WINDOW_BLOCKS);

        vm.roll(block.number + 3);
        assertEq(hook.blocksUntilDeadline(poolId), BATCH_WINDOW_BLOCKS - 3);
    }

    function testBlocksUntilDeadline_ZeroWhenOverdue() public {
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        vm.roll(hook.batchDeadline(poolId) + 5);
        assertEq(hook.blocksUntilDeadline(poolId), 0);
    }

    // ---------------------------------------------------------------------
    // Multi-pool isolation
    // ---------------------------------------------------------------------

    function _initSecondPoolOnSameHook() private returns (PoolKey memory poolKey2, PoolId poolId2) {
        (Currency currency2, Currency currency3) = deployCurrencyPair();
        poolKey2 = PoolKey(currency2, currency3, 3000, 60, IHooks(hook));
        poolId2 = poolKey2.toId();
        poolManager.initialize(poolKey2, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey2.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey2.tickSpacing);
        uint128 liquidityAmount = 1000e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );
        positionManager.mint(
            poolKey2,
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

    function testMultiPool_QueuesAreIndependent() public {
        (PoolKey memory poolKey2, PoolId poolId2) = _initSecondPoolOnSameHook();

        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.queueLength(poolId), 1);
        assertEq(hook.queueLength(poolId2), 0, "second pool's queue must be untouched");

        swapRouter.swapExactTokensForTokens({
            amountIn: 8e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey2,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.queueLength(poolId), 1, "first pool's queue must be untouched by the second pool's order");
        assertEq(hook.queueLength(poolId2), 1);
    }

    function testMultiPool_SettlingOneDoesNotAffectTheOther() public {
        (PoolKey memory poolKey2, PoolId poolId2) = _initSecondPoolOnSameHook();
        address trader1 = makeAddr("multiPoolTrader1");
        address trader2 = makeAddr("multiPoolTrader2");

        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(trader1),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: 8e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey2,
            hookData: abi.encode(trader2),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.roll(hook.batchDeadline(poolId));
        hook.settle(poolKey);

        assertEq(hook.queueLength(poolId), 0);
        assertEq(hook.queueLength(poolId2), 1, "settling pool 1 must not touch pool 2's queue");
        assertGt(currency1.balanceOf(trader1), 0);
    }

    function testFuzz_MaxBatchSizeNeverExceeded(uint8 rawExtraOrders) public {
        uint256 totalOrders = MAX_BATCH_SIZE + bound(rawExtraOrders, 0, 10);

        for (uint256 i = 0; i < totalOrders; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 10e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: abi.encode(makeAddr(string.concat("capFuzzTrader", vm.toString(i)))),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
            assertLe(hook.queueLength(poolId), MAX_BATCH_SIZE, "queue must never exceed the configured cap");
        }
    }

    // ---------------------------------------------------------------------
    // More CLVR worked examples, and Fix 5 (deterministic tie-breaking)
    // ---------------------------------------------------------------------

    function testCLVR_SingleOrder_ExecutesAlone() public {
        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();
        address trader = makeAddr("soloTrader");

        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(trader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, trader, true, 5e18, 0);

        vm.roll(clvrHook.batchDeadline(clvrPoolId));
        clvrHook.settle(clvrPoolKey);

        assertEq(clvrHook.queueLength(clvrPoolId), 0);
    }

    /// @dev Per the paper (Section 5.7): with exactly two same-direction pending trades, the
    /// optimal ordering that minimizes price volatility always executes the smaller one first.
    function testCLVR_TwoOrders_SmallerExecutesFirst() public {
        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();
        address smallTrader = makeAddr("smallTrader");
        address largeTrader = makeAddr("largeTrader");

        // Submitted large-first, small-second - the opposite of the expected execution order.
        swapRouter.swapExactTokensForTokens({
            amountIn: 20e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(largeTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: 3e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(smallTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, smallTrader, true, 3e18, 0);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, largeTrader, true, 20e18, 1);

        vm.roll(clvrHook.batchDeadline(clvrPoolId));
        clvrHook.settle(clvrPoolKey);
    }

    /// @dev Per the paper (Section 5.7): when every pending trade moves price in the same
    /// direction, the optimal ordering executes smallest to largest.
    function testCLVR_AllSameDirection_ExecutesSmallestToLargest() public {
        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();

        uint256[4] memory amounts = [uint256(8e18), 2e18, 15e18, 5e18];
        address[4] memory traders;
        for (uint256 i = 0; i < 4; i++) {
            traders[i] = makeAddr(string.concat("scrambledTrader", vm.toString(i)));
            swapRouter.swapExactTokensForTokens({
                amountIn: amounts[i],
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: clvrPoolKey,
                hookData: abi.encode(traders[i]),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        // Expected order by size: traders[1] (2e18), traders[3] (5e18), traders[0] (8e18),
        // traders[2] (15e18) - not the scrambled arrival order they were submitted in.
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traders[1], true, 2e18, 0);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traders[3], true, 5e18, 1);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traders[0], true, 8e18, 2);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traders[2], true, 15e18, 3);

        vm.roll(clvrHook.batchDeadline(clvrPoolId));
        clvrHook.settle(clvrPoolKey);
    }

    /// @dev Fix 5: two orders with identical direction and size produce an exact deviation
    /// tie at every step. CLVR must deterministically prefer whichever arrived first - never
    /// a discretionary or ambiguous choice.
    /// @dev Ties used to be broken by arrival order alone - deterministic, but exploitable:
    /// an attacker forcing a tie by matching the victim's exact trade size always arrives
    /// first by definition of front-running, so "earliest wins" always handed them the win.
    /// Verified empirically in SandwichDemo.t.sol, not just reasoned about - a size-matched
    /// front-run produced identical profit to a plain, unprotected pool.
    ///
    /// Superseded finding, kept here for the history: an earlier version of this fix keyed
    /// the tie-break on blockhash(block.number - 1) so the winner of an exact tie wasn't
    /// predictable at submission time. That was real progress (proven: the winner genuinely
    /// varied across settlement blocks) but not the actual fix - checking the real expected
    /// value across outcomes (see SandwichDemo.t.sol) showed an unpredictable-per-attempt
    /// coin flip is still strongly profitable on average, since "can't be predicted in
    /// advance" and "not worth attempting" are different properties.
    ///
    /// The actual fix removes the coin flip instead of just making it fair: two or more
    /// exactly-tied orders (identical amountIn and direction) are merged into one combined
    /// settlement instead of executed in sequence, so there is no "winner" of the tie to
    /// pick at all. This test proves that: across many different settlement blocks, both
    /// tied traders settle at the *same* settlementStep every single time - not sometimes
    /// one first and sometimes the other, but never separated into a first/second at all.
    function testCLVR_ExactTie_AlwaysMergesRegardlessOfSettlementBlock() public {
        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();

        for (uint256 trial = 0; trial < 8; trial++) {
            address firstTrader = makeAddr(string.concat("mergeTieFirst", vm.toString(trial)));
            address secondTrader = makeAddr(string.concat("mergeTieSecond", vm.toString(trial)));

            swapRouter.swapExactTokensForTokens({
                amountIn: 5e18,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: clvrPoolKey,
                hookData: abi.encode(firstTrader),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
            swapRouter.swapExactTokensForTokens({
                amountIn: 5e18,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: clvrPoolKey,
                hookData: abi.encode(secondTrader),
                receiver: address(this),
                deadline: block.timestamp + 1
            });

            // A different settlement block each trial - in a live pool nobody chooses
            // exactly which block settlement lands in.
            vm.roll(clvrHook.batchDeadline(clvrPoolId) + trial);

            vm.recordLogs();
            clvrHook.settle(clvrPoolKey);
            Vm.Log[] memory entries = vm.getRecordedLogs();

            bytes32 orderSettledTopic0 = keccak256("OrderSettled(bytes32,address,bool,uint256,uint256)");
            uint256 firstTraderStep = type(uint256).max;
            uint256 secondTraderStep = type(uint256).max;
            for (uint256 i = 0; i < entries.length; i++) {
                if (entries[i].topics.length == 0 || entries[i].topics[0] != orderSettledTopic0) continue;

                (,, uint256 settlementStep) = abi.decode(entries[i].data, (bool, uint256, uint256));
                address trader = address(uint160(uint256(entries[i].topics[2])));
                if (trader == firstTrader) firstTraderStep = settlementStep;
                if (trader == secondTrader) secondTraderStep = settlementStep;
            }

            assertTrue(firstTraderStep != type(uint256).max, "first trader must have settled");
            assertTrue(secondTraderStep != type(uint256).max, "second trader must have settled");
            assertEq(
                firstTraderStep,
                secondTraderStep,
                "an exact tie must merge - both traders settling at the same step, every trial, regardless of block"
            );
        }
    }

    /// @dev Same tie-break, settled at the same block every time, must always produce the
    /// same winner - the rule is a deterministic function of settlement-time state, not
    /// actual randomness. Unpredictable-in-advance and non-deterministic are different
    /// properties; this checks the fix didn't accidentally trade one for the other.
    function testCLVR_TieBreak_DeterministicForAFixedSettlementBlock() public {
        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();

        address firstTrader = makeAddr("deterministicTieFirst");
        address secondTrader = makeAddr("deterministicTieSecond");

        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(firstTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(secondTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 settlementBlock = clvrHook.batchDeadline(clvrPoolId) + 7;
        vm.roll(settlementBlock);

        // Snapshot right before settling, so it can be replayed from the exact same starting
        // state at the exact same block number.
        uint256 snapshot = vm.snapshotState();
        clvrHook.settle(clvrPoolKey);
        bool firstWonRunA = CurrencyLibrary.balanceOf(clvrPoolKey.currency1, firstTrader) > 0;

        vm.revertToState(snapshot);
        vm.roll(settlementBlock);
        clvrHook.settle(clvrPoolKey);
        bool firstWonRunB = CurrencyLibrary.balanceOf(clvrPoolKey.currency1, firstTrader) > 0;

        assertEq(firstWonRunA, firstWonRunB, "settling at the identical block must always produce the identical winner");
    }

    function testFuzz_CLVR_SettlesEveryOrderExactlyOnce(uint8 rawCount, uint256 seed) public {
        uint256 count = bound(rawCount, 2, 10);
        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();

        for (uint256 i = 0; i < count; i++) {
            address trader = makeAddr(string.concat("completenessTrader", vm.toString(i)));
            uint256 amt = bound(uint256(keccak256(abi.encode(seed, i))), 1e18, 30e18);
            bool dir = uint256(keccak256(abi.encode(seed, i, "dir"))) % 2 == 0;
            swapRouter.swapExactTokensForTokens({
                amountIn: amt,
                amountOutMin: 0,
                zeroForOne: dir,
                poolKey: clvrPoolKey,
                hookData: abi.encode(trader),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        assertEq(clvrHook.queueLength(clvrPoolId), count);

        vm.roll(clvrHook.batchDeadline(clvrPoolId));
        clvrHook.settle(clvrPoolKey);

        assertEq(clvrHook.queueLength(clvrPoolId), 0, "every queued order must be settled, none left behind");
        assertEq(clvrHook.batchDeadline(clvrPoolId), 0);
    }

    // ---------------------------------------------------------------------
    // hookData and exact-output edge cases
    // ---------------------------------------------------------------------

    function testHookData_WrongLengthFallsBackToSender() public {
        // hookData that's neither empty nor exactly 32 bytes should fall back to `sender`
        // (the router), not attempt to decode garbage as an address.
        bytes memory oddLength = new bytes(5);

        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: oddLength,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        CadenceHook.QueuedOrder memory order = hook.queuedOrder(poolId, 0);
        assertEq(order.trader, address(swapRouter));
    }

    function testExactOutputSwap_DoesNotContributeToCumulativeWindow() public {
        // Exact-output swaps must never feed the below-threshold cumulative tracker - they're
        // out of scope for batching entirely, not just individually small.
        for (uint256 i = 0; i < 3; i++) {
            swapRouter.swapTokensForExactTokens({
                amountOut: 1e18,
                amountInMax: type(uint256).max,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        // If exact-output swaps had incorrectly fed the cumulative tracker, this genuinely
        // small exact-input trade could already have crossed the threshold by now.
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        assertGt(swapDelta.amount1(), 0, "small trade should still execute instantly");
        assertEq(hook.queueLength(poolId), 0);
    }

    // ---------------------------------------------------------------------
    // Deadline boundary precision
    // ---------------------------------------------------------------------

    function testSettlement_OneBlockBeforeDeadline_DoesNotAutoSettle() public {
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 deadline = hook.batchDeadline(poolId);
        vm.roll(deadline - 1);

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Still one block shy of the deadline - the earlier batch must still be open.
        assertEq(hook.batchDeadline(poolId), deadline);
        assertGt(hook.queueLength(poolId), 0);
    }

    function testSettlement_ExactlyAtDeadlineBlock_AutoSettles() public {
        address beneficiary = makeAddr("exactDeadlineTrader");
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(beneficiary),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 deadline = hook.batchDeadline(poolId);
        vm.roll(deadline);

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertGt(currency1.balanceOf(beneficiary), 0, "batch must settle exactly at the deadline block, not after");
    }

    // ---------------------------------------------------------------------
    // Multiple consecutive batches
    // ---------------------------------------------------------------------

    function testMultipleBatches_SecondBatchOpensCleanlyAfterFirstSettles() public {
        address firstBeneficiary = makeAddr("firstBatchTrader");
        address secondBeneficiary = makeAddr("secondBatchTrader");

        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(firstBeneficiary),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        vm.roll(hook.batchDeadline(poolId));
        hook.settle(poolKey);
        assertEq(hook.queueLength(poolId), 0);
        assertEq(hook.batchDeadline(poolId), 0);

        // A second batch should open fresh, completely independent of the first.
        uint256 secondBatchStartBlock = block.number;
        swapRouter.swapExactTokensForTokens({
            amountIn: 12e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: abi.encode(secondBeneficiary),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.queueLength(poolId), 1);
        assertEq(hook.batchDeadline(poolId), secondBatchStartBlock + BATCH_WINDOW_BLOCKS);

        vm.roll(hook.batchDeadline(poolId));
        hook.settle(poolKey);

        assertGt(currency1.balanceOf(firstBeneficiary), 0);
        assertGt(currency0.balanceOf(secondBeneficiary), 0);
    }

    // ---------------------------------------------------------------------
    // Constructor parameters, fuzzed
    // ---------------------------------------------------------------------

    function _deployCustomPool(uint256 threshold, uint256 window, uint256 maxSize, uint160 saltBits)
        private
        returns (CadenceHook customHook, PoolKey memory customPoolKey)
    {
        address flagsAddr =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (saltBits << 144));
        bytes memory args = abi.encode(poolManager, threshold, window, maxSize);
        deployCodeTo("CadenceHook.sol:CadenceHook", args, flagsAddr);
        customHook = CadenceHook(flagsAddr);

        (Currency c0, Currency c1) = deployCurrencyPair();
        customPoolKey = PoolKey(c0, c1, 3000, 60, IHooks(customHook));
        poolManager.initialize(customPoolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(customPoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(customPoolKey.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            1000e18
        );
        positionManager.mint(
            customPoolKey,
            tickLower,
            tickUpper,
            1000e18,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testFuzz_ConstructorParams_ThresholdRespectedAcrossConfigs(uint256 customThreshold, uint256 testAmount)
        public
    {
        customThreshold = bound(customThreshold, 1e15, 20e18);
        testAmount = bound(testAmount, 1e14, 30e18);

        (CadenceHook customHook, PoolKey memory customPoolKey) =
            _deployCustomPool(customThreshold, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE, 0xCCCC);
        PoolId customPoolId = customPoolKey.toId();

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: testAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: customPoolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        if (testAmount < customThreshold) {
            assertGt(swapDelta.amount1(), 0);
            assertEq(customHook.queueLength(customPoolId), 0);
        } else {
            assertEq(swapDelta.amount1(), 0);
            assertEq(customHook.queueLength(customPoolId), 1);
        }
    }

    function testFuzz_ConstructorParams_WindowLengthRespected(uint256 customWindow) public {
        customWindow = bound(customWindow, 1, 200);

        (CadenceHook customHook, PoolKey memory customPoolKey) =
            _deployCustomPool(1e18, customWindow, MAX_BATCH_SIZE, 0xDDDD);
        uint256 startBlock = block.number;

        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: customPoolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(customHook.batchDeadline(customPoolKey.toId()), startBlock + customWindow);
    }

    function testFuzz_ConstructorParams_MaxBatchSizeRespected(uint8 rawCustomMax) public {
        uint256 customMax = bound(rawCustomMax, 1, 15);

        (CadenceHook customHook, PoolKey memory customPoolKey) =
            _deployCustomPool(1e18, BATCH_WINDOW_BLOCKS, customMax, 0xEEEE);
        PoolId customPoolId = customPoolKey.toId();

        for (uint256 i = 0; i < customMax; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 5e18,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: customPoolKey,
                hookData: abi.encode(makeAddr(string.concat("customCapTrader", vm.toString(i)))),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
            assertLe(customHook.queueLength(customPoolId), customMax);
        }
        assertEq(customHook.queueLength(customPoolId), 0, "must force-settle exactly at the custom cap");
    }

    // ---------------------------------------------------------------------
    // Direction symmetry
    // ---------------------------------------------------------------------

    function testCLVR_TwoOrders_SmallerExecutesFirst_OppositeDirection() public {
        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();
        address smallTrader = makeAddr("smallBuyTrader");
        address largeTrader = makeAddr("largeBuyTrader");

        swapRouter.swapExactTokensForTokens({
            amountIn: 20e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: clvrPoolKey,
            hookData: abi.encode(largeTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: 3e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: clvrPoolKey,
            hookData: abi.encode(smallTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, smallTrader, false, 3e18, 0);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, largeTrader, false, 20e18, 1);

        vm.roll(clvrHook.batchDeadline(clvrPoolId));
        clvrHook.settle(clvrPoolKey);
    }

    // ---------------------------------------------------------------------
    // Event field verification
    // ---------------------------------------------------------------------

    function testOrderQueued_EventFieldsAreCorrect() public {
        address trader = makeAddr("eventFieldsTrader");
        uint256 amountIn = 12e18;
        uint256 expectedDeadline = block.number + BATCH_WINDOW_BLOCKS;

        vm.expectEmit(true, true, false, true, address(hook));
        emit CadenceHook.OrderQueued(poolId, trader, true, amountIn, 0, expectedDeadline);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(trader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function testBatchSettled_EventReportsCorrectOrderCount() public {
        for (uint256 i = 0; i < 3; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 10e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: abi.encode(makeAddr(string.concat("batchCountTrader", vm.toString(i)))),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        vm.expectEmit(true, false, false, true, address(hook));
        emit CadenceHook.BatchSettled(poolId, 3);

        vm.roll(hook.batchDeadline(poolId));
        hook.settle(poolKey);
    }

    function testOrderSkipped_EventFieldsAreCorrect() public {
        (CadenceHook grHook, PoolKey memory grPoolKey, MockERC20 goodToken, BlacklistingToken badToken) =
            _deployGriefingTestPool();
        PoolId grPoolId = grPoolKey.toId();
        bool badIsCurrency1 = Currency.unwrap(grPoolKey.currency1) == address(badToken);
        address blacklistedTrader = makeAddr("skippedEventTrader");
        badToken.setBlacklisted(blacklistedTrader);
        goodToken; // silence unused-var warning; balances aren't checked in this event-focused test

        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: badIsCurrency1,
            poolKey: grPoolKey,
            hookData: abi.encode(blacklistedTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.expectEmit(true, true, false, true, address(grHook));
        emit CadenceHook.OrderSkipped(grPoolId, blacklistedTrader, badIsCurrency1, 10e18, 0);

        vm.roll(grHook.batchDeadline(grPoolId));
        grHook.settle(grPoolKey);
    }

    // ---------------------------------------------------------------------
    // Configuration boundary values
    // ---------------------------------------------------------------------

    function testConfig_ZeroThreshold_AlwaysQueuesEveryTrade() public {
        // batchThreshold = 0 is a valid, if extreme, configuration: every exact-input trade
        // (specifiedAmount is never negative) meets "amount >= threshold" and queues.
        (CadenceHook customHook, PoolKey memory customPoolKey) =
            _deployCustomPool(0, BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE, 0xFFFF);
        PoolId customPoolId = customPoolKey.toId();

        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: 1e14, // tiny by any normal standard
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: customPoolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(swapDelta.amount1(), 0, "even a tiny trade must queue when threshold is zero");
        assertEq(customHook.queueLength(customPoolId), 1);
    }

    function testConfig_MaxBatchSizeOfOne_SettlesEachOrderAlone() public {
        // maxBatchSize = 1 means every above-threshold order force-settles itself immediately
        // - the batch never actually accumulates more than one order at a time.
        (CadenceHook customHook, PoolKey memory customPoolKey) =
            _deployCustomPool(1e18, BATCH_WINDOW_BLOCKS, 1, 0x1234);
        PoolId customPoolId = customPoolKey.toId();
        address trader = makeAddr("soloCapTrader");

        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: customPoolKey,
            hookData: abi.encode(trader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Settled immediately within the same call that queued it - never sat in the queue
        // waiting for a second order or the deadline.
        assertEq(customHook.queueLength(customPoolId), 0);
        assertEq(customHook.batchDeadline(customPoolId), 0);
    }

    // ---------------------------------------------------------------------
    // Gas benchmarking
    // ---------------------------------------------------------------------

    function testGas_SingleOrderQueueing() public {
        uint256 gasBefore = gasleft();
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 500_000, "queueing a single order should be cheap - no settlement work happens here");
    }

    function testGas_SettlementAtMaxBatchSize() public {
        for (uint256 i = 0; i < MAX_BATCH_SIZE - 1; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 10e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: abi.encode(makeAddr(string.concat("gasTrader", vm.toString(i)))),
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }
        // Still well before the deadline - only the size cap can trigger the next push.
        assertLt(block.number, hook.batchDeadline(poolId));

        uint256 gasBefore = gasleft();
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(makeAddr("gasTraderLast")),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(hook.queueLength(poolId), 0, "cap must have force-settled the full batch");
        // Well under a single block's gas limit (~30M on mainnet) even at the batch-size cap
        // - the O(n^2) CLVR cost stays practical once batch size is bounded.
        assertLt(gasUsed, 20_000_000, "settling a full-size batch must stay well under typical block gas limits");
    }

    // ---------------------------------------------------------------------
    // CLVR ordering, fuzzed sort property
    // ---------------------------------------------------------------------

    /// @dev Fuzzed version of the paper's "same-direction batches execute smallest to
    /// largest" claim (Section 5.7): for any three random same-direction amounts, CLVR's
    /// actual execution order must match ascending sort order.
    function testFuzz_CLVR_ThreeSameDirectionOrders_SortedAscending(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1e18, 30e18);
        b = bound(b, 1e18, 30e18);
        c = bound(c, 1e18, 30e18);
        vm.assume(a != b && b != c && a != c);

        (CadenceHook clvrHook, PoolKey memory clvrPoolKey) = _deployClvrTestPool();
        PoolId clvrPoolId = clvrPoolKey.toId();

        address traderA = makeAddr("sortA");
        address traderB = makeAddr("sortB");
        address traderC = makeAddr("sortC");

        swapRouter.swapExactTokensForTokens({
            amountIn: a,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(traderA),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: b,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(traderB),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: c,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: clvrPoolKey,
            hookData: abi.encode(traderC),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256[3] memory amounts = [a, b, c];
        address[3] memory traders = [traderA, traderB, traderC];
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (amounts[j] < amounts[i]) {
                    (amounts[i], amounts[j]) = (amounts[j], amounts[i]);
                    (traders[i], traders[j]) = (traders[j], traders[i]);
                }
            }
        }

        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traders[0], true, amounts[0], 0);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traders[1], true, amounts[1], 1);
        vm.expectEmit(true, true, false, true, address(clvrHook));
        emit CadenceHook.OrderSettled(clvrPoolId, traders[2], true, amounts[2], 2);

        vm.roll(clvrHook.batchDeadline(clvrPoolId));
        clvrHook.settle(clvrPoolKey);
    }

    // ---------------------------------------------------------------------
    // Reentrancy, distinct attack shape: nested settle() rather than nested swap()
    // ---------------------------------------------------------------------

    function _deploySettleReentrancyTestPool()
        private
        returns (CadenceHook srHook, PoolKey memory srPoolKey, MockERC20 goodToken, SettleReentrantToken badToken)
    {
        goodToken = new MockERC20("Good Token", "GOOD", 18);
        badToken = new SettleReentrantToken("Settle Reentrant Token", "SRT", 18);

        goodToken.mint(address(this), 10_000_000 ether);
        badToken.mint(address(this), 10_000_000 ether);

        goodToken.approve(address(permit2), type(uint256).max);
        goodToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(goodToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(goodToken), address(poolManager), type(uint160).max, type(uint48).max);

        badToken.approve(address(permit2), type(uint256).max);
        badToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(badToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(badToken), address(poolManager), type(uint160).max, type(uint48).max);

        (Currency srCurrency0, Currency srCurrency1) = address(goodToken) < address(badToken)
            ? (Currency.wrap(address(goodToken)), Currency.wrap(address(badToken)))
            : (Currency.wrap(address(badToken)), Currency.wrap(address(goodToken)));

        address flags9 =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x9111 << 144));
        bytes memory args9 = abi.encode(poolManager, uint256(1e18), BATCH_WINDOW_BLOCKS, MAX_BATCH_SIZE);
        deployCodeTo("CadenceHook.sol:CadenceHook", args9, flags9);
        srHook = CadenceHook(flags9);

        srPoolKey = PoolKey(srCurrency0, srCurrency1, 3000, 60, IHooks(srHook));
        poolManager.initialize(srPoolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(srPoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(srPoolKey.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            1000e18
        );
        positionManager.mint(
            srPoolKey,
            tickLower,
            tickUpper,
            1000e18,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        badToken.arm(ISettleCallable(address(srHook)), srPoolKey);
    }

    function testReentrancy_SettleCallAttemptedDuringSettlementIsRejected() public {
        (CadenceHook srHook, PoolKey memory srPoolKey, MockERC20 goodToken, SettleReentrantToken badToken) =
            _deploySettleReentrancyTestPool();
        PoolId srPoolId = srPoolKey.toId();
        bool badIsCurrency1 = Currency.unwrap(srPoolKey.currency1) == address(badToken);

        address victim = makeAddr("settleReentrancyVictim");
        address otherTrader = makeAddr("settleReentrancyOther");

        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: badIsCurrency1,
            poolKey: srPoolKey,
            hookData: abi.encode(victim),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: !badIsCurrency1,
            poolKey: srPoolKey,
            hookData: abi.encode(otherTrader),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.roll(srHook.batchDeadline(srPoolId));
        srHook.settle(srPoolKey);

        assertTrue(badToken.reentryAttempted(), "malicious token should have attempted a nested settle() call");
        assertTrue(
            badToken.reentryReverted(),
            "PoolManager's own AlreadyUnlocked guard must reject the nested unlock, independent of CadenceHook"
        );

        // The token catches its own reentrant attempt internally, so its transfer() still
        // succeeds overall - the victim is paid normally, and so is the unrelated order.
        assertEq(srHook.queueLength(srPoolId), 0);
        assertGt(badToken.balanceOf(victim), 0, "victim should still receive their real payout");
        assertGt(goodToken.balanceOf(otherTrader), 0, "the other queued order should settle normally too");
    }
}
