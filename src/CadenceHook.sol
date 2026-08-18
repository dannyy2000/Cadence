// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHookEvents} from "@openzeppelin/uniswap-hooks/src/interfaces/IHookEvents.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Batches large trades into fixed-length windows instead of letting them execute
/// one at a time against the AMM curve, then settles the whole batch atomically. Settlement
/// currently uses a naive sequential-execution placeholder rather than the CLVR ordering
/// rule described in the project README — see `_settle` and MILESTONES.md for what that
/// means and what M2 replaces it with.
contract CadenceHook is BaseHook, IHookEvents {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencySettler for Currency;

    struct QueuedOrder {
        address trader;
        bool zeroForOne;
        uint256 amountIn;
        uint256 blockNumber;
    }

    /// @dev Minimum specified input amount (in the input token's own raw units) that routes
    /// a trade into the batch queue instead of instant execution. A single flat threshold
    /// is a simplification for now — cumulative price-impact-based thresholding and evasion
    /// resistance (order-splitting) are M2 hardening work, not implemented here yet.
    uint256 public immutable batchThreshold;

    /// @dev Length of a batch window, in blocks.
    uint256 public immutable batchWindowBlocks;

    /// @dev Queued orders per pool, in arrival order. Cleared on settlement (not yet implemented).
    mapping(PoolId => QueuedOrder[]) private _batchQueue;

    /// @dev Block number at which the current batch becomes eligible to settle. 0 means no
    /// batch is currently open for that pool.
    mapping(PoolId => uint256) public batchDeadline;

    /// @dev True only while `_settle` is executing its own swaps against the pool. Guards
    /// against those swaps recursing back into `_beforeSwap`'s threshold/queue logic.
    bool private _settling;

    event OrderQueued(
        PoolId indexed poolId,
        address indexed trader,
        bool zeroForOne,
        uint256 amountIn,
        uint256 queuePosition,
        uint256 deadline
    );

    event BatchSettled(PoolId indexed poolId, uint256 ordersSettled);

    error BatchNotDue();

    constructor(IPoolManager _poolManager, uint256 _batchThreshold, uint256 _batchWindowBlocks)
        BaseHook(_poolManager)
    {
        require(_batchWindowBlocks > 0, "batchWindowBlocks must be > 0");
        batchThreshold = _batchThreshold;
        batchWindowBlocks = _batchWindowBlocks;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_settling) {
            // One of this hook's own settlement swaps, calling back into this same
            // beforeSwap. Pass it through untouched — it must not be re-queued or trigger
            // settlement again, or settlement would recurse into itself.
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId poolId = key.toId();
        uint256 deadline = batchDeadline[poolId];
        if (deadline != 0 && block.number >= deadline) {
            // Primary trigger: whoever trades next after the deadline settles the previous
            // batch as a mandatory first step of their own transaction, before their own
            // trade is even considered. No separate reward exists for doing this, so
            // there's nothing for anyone to time or game.
            _settle(poolId, key);
        }

        // Exact-output swaps pass through untouched. Intercepting them into the batch queue
        // would need the hook to quote an output before knowing the settlement price, which
        // isn't meaningful for a batched order — same scope limit the async-swap pattern
        // this borrows from uses.
        if (params.amountSpecified >= 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 specifiedAmount = uint256(-params.amountSpecified);

        if (specifiedAmount < batchThreshold) {
            // Below threshold: instant execution, identical to a plain Uniswap swap.
            // No batching, no added latency, no added cost.
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        Currency specified = params.zeroForOne ? key.currency0 : key.currency1;

        // Pull the full input into hook custody (as ERC-6909 claim tokens) instead of letting
        // it execute against the AMM curve. This is the mechanical core of batching: the trade
        // does not move the pool price at all until settlement processes the whole batch together.
        specified.take(poolManager, address(this), specifiedAmount, true);

        // `sender` here is typically a router contract, not the wallet that submitted the
        // trade, so it isn't safe to use as the payout address for settlement (which happens
        // in a later, unrelated transaction the router has no way to react to). Callers that
        // want settlement proceeds sent to a specific address encode it as hookData; anything
        // else falls back to `sender`.
        address beneficiary = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;

        _batchQueue[poolId].push(
            QueuedOrder({
                trader: beneficiary,
                zeroForOne: params.zeroForOne,
                amountIn: specifiedAmount,
                blockNumber: block.number
            })
        );

        if (batchDeadline[poolId] == 0) {
            batchDeadline[poolId] = block.number + batchWindowBlocks;
        }

        emit OrderQueued(
            poolId,
            beneficiary,
            params.zeroForOne,
            specifiedAmount,
            _batchQueue[poolId].length - 1,
            batchDeadline[poolId]
        );

        if (params.zeroForOne) {
            emit HookSwap(PoolId.unwrap(poolId), beneficiary, specifiedAmount.toInt128(), 0, 0, 0);
        } else {
            emit HookSwap(PoolId.unwrap(poolId), beneficiary, 0, specifiedAmount.toInt128(), 0, 0);
        }

        // Net the specified amount to zero so the PoolManager treats this swap's input as
        // fully handled by the hook. The caller receives no output yet — that only happens
        // once settlement clears the batch.
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(specifiedAmount.toInt128(), 0), 0);
    }

    /// @notice Fallback trigger: if a pool goes quiet after a batch opens, anyone — including
    /// a trader stuck in the queue — can force settlement once the deadline has passed,
    /// instead of being dependent on someone else happening to trade next.
    ///
    /// Unlike the primary trigger (which runs from inside an already-in-progress swap, and
    /// so is already inside the `PoolManager`'s unlocked context), a standalone call here
    /// has to open that context itself before it's allowed to call `swap`/`take`/`settle` —
    /// hence the `unlock` round-trip instead of calling `_settle` directly.
    function settle(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        uint256 deadline = batchDeadline[poolId];
        if (deadline == 0 || block.number < deadline) revert BatchNotDue();
        poolManager.unlock(abi.encode(key));
    }

    /// @dev Called back by the `PoolManager` after `settle`'s `unlock` call. Only the
    /// `PoolManager` itself can call this.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        _settle(key.toId(), key);
        return bytes("");
    }

    /// @dev Naive placeholder clearing rule: executes each queued order sequentially against
    /// the pool, within this one atomic transaction. Because it's all one transaction, none of
    /// these trades can be sandwiched by an outside party — there's no gap between them for
    /// anyone to insert into. What this does NOT yet give every order is the same clearing
    /// price: the first order in the loop still gets a marginally better price than the last,
    /// since each swap moves the pool price for the next. Replacing this loop with the CLVR
    /// ordering rule (which computes a single deviation-minimizing settlement for the whole
    /// batch instead of executing sequentially) is the M2 milestone.
    function _settle(PoolId poolId, PoolKey memory key) internal {
        QueuedOrder[] memory orders = _batchQueue[poolId];
        uint256 n = orders.length;

        _settling = true;
        for (uint256 i = 0; i < n; i++) {
            QueuedOrder memory order = orders[i];

            BalanceDelta delta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: order.zeroForOne,
                    amountSpecified: -int256(order.amountIn),
                    sqrtPriceLimitX96: order.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                bytes("")
            );

            Currency input = order.zeroForOne ? key.currency0 : key.currency1;
            Currency output = order.zeroForOne ? key.currency1 : key.currency0;

            // Pay for this order's swap by burning the claim tokens taken from the trader
            // when they joined the queue.
            input.settle(poolManager, address(this), order.amountIn, true);

            // Send the real output tokens straight to whoever should receive them.
            uint256 outputAmount =
                order.zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
            output.take(poolManager, order.trader, outputAmount, false);
        }
        _settling = false;

        delete _batchQueue[poolId];
        batchDeadline[poolId] = 0;

        emit BatchSettled(poolId, n);
    }

    function queueLength(PoolId poolId) external view returns (uint256) {
        return _batchQueue[poolId].length;
    }

    function queuedOrder(PoolId poolId, uint256 index) external view returns (QueuedOrder memory) {
        return _batchQueue[poolId][index];
    }

    function blocksUntilDeadline(PoolId poolId) external view returns (uint256) {
        uint256 deadline = batchDeadline[poolId];
        if (deadline == 0 || block.number >= deadline) return 0;
        return deadline - block.number;
    }
}
