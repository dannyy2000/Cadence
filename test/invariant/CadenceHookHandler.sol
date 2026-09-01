// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {CadenceHook} from "../../src/CadenceHook.sol";

/// @notice Drives randomized sequences of swaps, block advances, and settlement calls against
/// a already-deployed CadenceHook pool, tracking ghost accounting the invariant tests check
/// against the hook's actual on-chain state after every sequence.
contract CadenceHookHandler is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Must match the deployed hook's real threshold (set by the invariant test's setUp) -
    // arbitrary for testing purposes, not a production value. See
    // script/00_DeployHook.s.sol for the calibrated one.
    uint256 public constant BATCH_THRESHOLD = 5e18;

    IPoolManager public immutable poolManager;
    IUniswapV4Router04 public immutable swapRouter;
    CadenceHook public immutable hook;
    PoolKey public poolKey;
    PoolId public immutable poolId;
    Currency public immutable currency0;
    Currency public immutable currency1;

    address[] public traders;

    /// @dev Sum of amountIn for currently-queued zeroForOne (currency0-in) orders.
    uint256 public ghost_queued0In;
    /// @dev Sum of amountIn for currently-queued oneForZero (currency1-in) orders.
    uint256 public ghost_queued1In;

    constructor(
        IPoolManager _poolManager,
        IUniswapV4Router04 _swapRouter,
        CadenceHook _hook,
        PoolKey memory _poolKey,
        Currency _currency0,
        Currency _currency1
    ) {
        poolManager = _poolManager;
        swapRouter = _swapRouter;
        hook = _hook;
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        currency0 = _currency0;
        currency1 = _currency1;

        for (uint256 i = 0; i < 5; i++) {
            traders.push(makeAddr(string.concat("handlerTrader", vm.toString(i))));
        }

        deal(Currency.unwrap(currency0), address(this), 1_000_000e18);
        deal(Currency.unwrap(currency1), address(this), 1_000_000e18);
        IERC20Approve(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Approve(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
    }

    function swap(uint256 amountSeed, bool zeroForOne, uint256 traderSeed) public {
        uint256 amountIn = bound(amountSeed, 1e14, 50e18);
        address beneficiary = traders[traderSeed % traders.length];

        // Mirror the primary trigger: if the deadline has already passed, the OLD batch
        // settles as the very first thing the real call does, before this trade's own amount
        // is even considered.
        uint256 deadlineBefore = hook.batchDeadline(poolId);
        bool deadlineTriggered = deadlineBefore != 0 && block.number >= deadlineBefore;

        uint256 queueLengthBefore = hook.queueLength(poolId);

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: abi.encode(beneficiary),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 queueLengthAfter = hook.queueLength(poolId);

        if (queueLengthAfter == 0) {
            // Nothing queued afterward - either there was nothing to begin with and this
            // trade didn't queue either, or a size-cap trigger cleared everything including
            // this trade (whether or not the deadline was also due first).
            ghost_queued0In = 0;
            ghost_queued1In = 0;
        } else if (deadlineTriggered) {
            // The old batch was wiped (regardless of what it held), and something is queued
            // afterward - since nothing else can act on an empty queue between that wipe and
            // this call returning, that something can only be this trade.
            ghost_queued0In = 0;
            ghost_queued1In = 0;
            if (zeroForOne) {
                ghost_queued0In = amountIn;
            } else {
                ghost_queued1In = amountIn;
            }
        } else if (queueLengthAfter > queueLengthBefore) {
            // No settlement happened - the queue only grows via this trade's own append,
            // whether it crossed the per-trade threshold or the cumulative order-splitting
            // one. A length increase can only be this trade, whichever path caused it.
            if (zeroForOne) {
                ghost_queued0In += amountIn;
            } else {
                ghost_queued1In += amountIn;
            }
        }
        // else: queueLengthAfter <= queueLengthBefore and > 0, deadline wasn't due - this
        // trade didn't queue (below both thresholds). Ghost unchanged.
    }

    function advanceBlocks(uint256 blocksSeed) public {
        uint256 blocksToAdvance = bound(blocksSeed, 0, 20);
        vm.roll(block.number + blocksToAdvance);
    }

    function settle() public {
        uint256 deadline = hook.batchDeadline(poolId);
        if (deadline == 0 || block.number < deadline) return;

        hook.settle(poolKey);
        ghost_queued0In = 0;
        ghost_queued1In = 0;
    }
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}
