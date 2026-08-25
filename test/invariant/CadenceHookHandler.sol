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

        // A settlement (primary/deadline, or size-cap) can happen at any point during this
        // call - before this trade's own amount is even considered (deadline overdue), or as
        // a direct result of this trade's own push (cap reached). Rather than predicting
        // which trigger fired, compare the real queue length against what it would be if NO
        // settlement happened at all: any shortfall means something settled, and every ghost
        // total that existed before this call must be treated as wiped, not just this trade's
        // own contribution.
        uint256 queueLengthBefore = hook.queueLength(poolId);
        bool thisOrderAttemptsToQueue = amountIn >= BATCH_THRESHOLD;
        uint256 expectedIfNoSettlement = queueLengthBefore + (thisOrderAttemptsToQueue ? 1 : 0);

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

        if (queueLengthAfter < expectedIfNoSettlement) {
            // Something settled during this call - wipe every ghost total that predates it.
            ghost_queued0In = 0;
            ghost_queued1In = 0;
            // This order still counts if it survived as the start of a fresh batch (settled
            // an old, overdue batch, then queued itself) rather than also being swept into a
            // cap-triggered self-settlement (queueLengthAfter == 0 either way).
            if (queueLengthAfter > 0 && thisOrderAttemptsToQueue) {
                if (zeroForOne) {
                    ghost_queued0In += amountIn;
                } else {
                    ghost_queued1In += amountIn;
                }
            }
        } else if (thisOrderAttemptsToQueue) {
            // No settlement happened - this order simply joined whatever was already queued.
            if (zeroForOne) {
                ghost_queued0In += amountIn;
            } else {
                ghost_queued1In += amountIn;
            }
        }
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
