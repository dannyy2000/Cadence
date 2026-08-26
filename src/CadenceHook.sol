// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHookEvents} from "@openzeppelin/uniswap-hooks/src/interfaces/IHookEvents.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Batches large trades into fixed-length windows instead of letting them execute
/// one at a time against the AMM curve, then settles the whole batch atomically using the
/// CLVR ordering rule (McLaughlin, Chemaya, Liu & Malkhi, "CLVR Ordering of Transactions on
/// AMMs", arXiv:2408.02634) — see `_settle` for the implementation and MILESTONES.md for
/// which security-hardening items are done versus still open.
contract CadenceHook is BaseHook, IHookEvents {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    struct QueuedOrder {
        address trader;
        bool zeroForOne;
        uint256 amountIn;
        uint256 blockNumber;
    }

    /// @dev Minimum specified input amount (in the input token's own raw units) that routes
    /// a trade into the batch queue instead of instant execution.
    uint256 public immutable batchThreshold;

    /// @dev Length of a batch window, in blocks.
    uint256 public immutable batchWindowBlocks;

    /// @dev Maximum number of orders a batch can hold before it force-settles immediately,
    /// regardless of the deadline. CLVR's selection step is O(n) work per order settled
    /// (O(n^2) total per batch) - without this cap, nothing stops a batch from growing large
    /// enough to make settlement's gas cost unpredictable, or from being deliberately grown
    /// that way as a griefing vector against whoever ends up triggering settlement.
    uint256 public immutable maxBatchSize;

    /// @dev Queued orders per pool, in arrival order. Cleared on settlement.
    mapping(PoolId => QueuedOrder[]) private _batchQueue;

    struct SmallTradeWindow {
        uint256 volume;
        uint256 windowStart;
    }

    /// @dev Tracks cumulative below-threshold trade volume per pool, per direction, within a
    /// rolling window (reused as `batchWindowBlocks` long, same as a batch window). Order
    /// splitting - chopping one large trade into many small ones to dodge the per-trade
    /// threshold - is a documented real evasion strategy. Without this, an attacker (or
    /// several colluding addresses) could push arbitrary same-direction volume through with
    /// zero batching protection. Tracking by direction rather than by address also catches
    /// splitting across multiple addresses, not just repeated use of one.
    mapping(PoolId => mapping(bool => SmallTradeWindow)) private _smallTradeWindow;

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

    /// @dev Emitted for each order as CLVR picks it, in the order it's actually executed -
    /// which generally differs from queuePosition (arrival order). Exists so the execution
    /// order is externally observable (for tests, and later for the frontend) without having
    /// to decode raw PoolManager Swap events.
    event OrderSettled(PoolId indexed poolId, address indexed trader, bool zeroForOne, uint256 amountIn, uint256 settlementStep);

    /// @dev Emitted instead of OrderSettled when an order's real execution fails and it gets
    /// refunded rather than paid out - see `_executeOrder`/`_refundOrder`.
    event OrderSkipped(PoolId indexed poolId, address indexed trader, bool zeroForOne, uint256 amountIn, uint256 settlementStep);

    event BatchSettled(PoolId indexed poolId, uint256 ordersSettled);

    error BatchNotDue();
    error ReentrantSwapDuringSettlement();
    error OnlySelf();

    constructor(IPoolManager _poolManager, uint256 _batchThreshold, uint256 _batchWindowBlocks, uint256 _maxBatchSize)
        BaseHook(_poolManager)
    {
        require(_batchWindowBlocks > 0, "batchWindowBlocks must be > 0");
        require(_maxBatchSize > 0, "maxBatchSize must be > 0");
        batchThreshold = _batchThreshold;
        batchWindowBlocks = _batchWindowBlocks;
        maxBatchSize = _maxBatchSize;
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
            // Only this hook's own settlement swaps - poolManager.swap() calls made
            // directly by this contract, from inside _settle - are allowed through
            // untouched while settlement is in progress. `sender` is whoever directly
            // called poolManager.swap(); for our own internal swaps that's always
            // address(this). Paying out a settled order can run external code (a native
            // ETH transfer invokes the recipient's receive(); a nonstandard ERC20 could do
            // the same from inside transfer()) - if that callback tried to sneak in its own
            // swap here, it would otherwise execute at whatever mid-settlement price CLVR
            // happened to be at that step, inserting an uncontrolled trade into what was
            // supposed to be one atomic, fairly-ordered settlement. Reject anything that
            // isn't genuinely us, rather than silently letting it through.
            if (sender != address(this)) revert ReentrantSwapDuringSettlement();
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
            SmallTradeWindow storage window = _smallTradeWindow[poolId][params.zeroForOne];

            if (window.windowStart == 0 || block.number > window.windowStart + batchWindowBlocks) {
                // No window open, or the old one expired without crossing the threshold -
                // start fresh with just this trade.
                window.windowStart = block.number;
                window.volume = specifiedAmount;
            } else {
                window.volume += specifiedAmount;
            }

            if (window.volume < batchThreshold) {
                // Still under the cumulative threshold for this window: instant execution,
                // identical to a plain Uniswap swap. No batching, no added latency, no added
                // cost - same as any other below-threshold trade.
                return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }

            // Cumulative same-direction volume just crossed the threshold within this window
            // - this trade (even though its own size is below the per-trade threshold) is the
            // one that gets swept into the batch queue, exactly like an ordinary above-
            // threshold trade would. Earlier pieces of the pattern already executed instantly
            // before the crossing was detected; this bounds how much total volume can evade
            // batching per window rather than catching every split piece retroactively.
            delete _smallTradeWindow[poolId][params.zeroForOne];
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

        if (_batchQueue[poolId].length >= maxBatchSize) {
            // Size-cap trigger: this order just took the batch to its gas-safety limit, so
            // it (and everything else queued) settles immediately as a side effect of this
            // same call, rather than waiting for the deadline.
            _settle(poolId, key);
        }

        // Net the specified amount to zero so the PoolManager treats this swap's input as
        // fully handled by the hook. The caller receives no output yet unless the size-cap
        // trigger above just settled it — that only happens once settlement clears the batch.
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
    ///
    /// `key` is caller-supplied, but pool-key spoofing isn't a real avenue here: `poolId` is
    /// `keccak256` of the entire key (currencies, fee, tickSpacing, and `hooks` together), the
    /// same strong hash `PoolManager` itself uses, so `_batchQueue`/`batchDeadline` can only
    /// ever have real entries at a `poolId` whose *only* valid preimage is the genuine key -
    /// there's no separate, looser identifier a mismatched key could collide with. Passing an
    /// unrelated key just derives an unrelated (empty) `poolId`, and `PoolManager.swap` itself
    /// would revert on an uninitialized pool regardless.
    ///
    /// Sequential double-settlement (calling this twice for the same batch) is already closed
    /// by the deadline check above: the first call clears `batchDeadline[poolId]` back to 0
    /// before returning, so a second call reverts with `BatchNotDue` rather than re-running
    /// `_settle` on an empty queue. Reentrant double-settlement (a second call arriving *during*
    /// the first) is closed one layer down, in `PoolManager.unlock` itself, which reverts with
    /// `AlreadyUnlocked` on any nested `unlock` call — independent of anything this contract
    /// does. What neither of those covers is a *swap* (not a nested `settle` call) sneaking in
    /// mid-settlement via a payout's external call; see the `sender != address(this)` check in
    /// `_beforeSwap` for that.
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

    /// @dev CLVR settlement: at each step, out of the orders not yet executed, run whichever
    /// one would land the pool's price closest to the reference price captured before this
    /// batch's settlement began — then actually execute it, and repeat. This is the O(n^2)
    /// algorithm the paper presents and proves sandwich-attack resistance for in its main
    /// text (Section 4.2 / Appendix C), not the O(n log n) reduction in Appendix G: with a
    /// batch size that's already gas-bounded (M2 hardening item), the O(n^2) cost is
    /// negligible, and it doesn't need a from-scratch balanced-tree structure to get right.
    ///
    /// Because it's all one atomic transaction, none of these trades can be sandwiched by an
    /// outside party — there's no gap between them for anyone to insert into. CLVR is what
    /// additionally makes the *internal* order fair, instead of leaving it as an arbitrary
    /// array order the way the earlier placeholder did.
    function _settle(PoolId poolId, PoolKey memory key) internal {
        QueuedOrder[] memory orders = _batchQueue[poolId];
        uint256 n = orders.length;
        if (n == 0) {
            batchDeadline[poolId] = 0;
            return;
        }

        (uint160 referenceSqrtPriceX96,,, uint24 lpFee) = poolManager.getSlot0(poolId);

        bool[] memory settled = new bool[](n);

        _settling = true;
        for (uint256 step = 0; step < n; step++) {
            (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            uint128 liquidity = poolManager.getLiquidity(poolId);

            uint256 bestIndex = type(uint256).max;
            uint256 bestDeviation = type(uint256).max;

            // Simulate every not-yet-executed order against the current (real, just-read)
            // pool state - a pure math projection via the same step function the pool itself
            // uses internally, without spending gas on an actual swap - and keep whichever
            // one deviates least from the reference price.
            for (uint256 j = 0; j < n; j++) {
                if (settled[j]) continue;

                QueuedOrder memory candidate = orders[j];
                uint160 sqrtPriceTargetX96 =
                    candidate.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

                (uint160 resultingSqrtPriceX96,,,) = SwapMath.computeSwapStep(
                    currentSqrtPriceX96, sqrtPriceTargetX96, liquidity, -int256(candidate.amountIn), lpFee
                );

                uint256 deviation = _deviationFromReference(referenceSqrtPriceX96, resultingSqrtPriceX96);
                // Strictly-less-than only: on an exact tie between two candidates, the
                // earlier one (lower j, i.e. whichever arrived at the queue first) keeps
                // `bestIndex` rather than being overwritten. Since `j` is scanned in a fixed,
                // deterministic order every time, this makes tie-breaking deterministic by
                // original submission order with no extra state or explicit rule needed - no
                // party, including the contract itself, ever makes a discretionary choice
                // between equally-valid orderings.
                if (deviation < bestDeviation) {
                    bestDeviation = deviation;
                    bestIndex = j;
                }
            }

            QueuedOrder memory winner = orders[bestIndex];
            settled[bestIndex] = true;

            // One malformed or now-infeasible order (e.g. a payout currency that blacklists
            // its recipient, or reverts for its own reasons) must not revert the whole
            // settlement transaction and strand every other order in the batch along with it
            // - a documented real failure pattern elsewhere in DeFi. _executeOrder does the
            // real work; a failure there is caught and the order is refunded on its own
            // instead of aborting the rest of the batch.
            try this._executeOrder(key, winner) {
                emit OrderSettled(poolId, winner.trader, winner.zeroForOne, winner.amountIn, step);
            } catch {
                _refundOrder(key, winner);
                emit OrderSkipped(poolId, winner.trader, winner.zeroForOne, winner.amountIn, step);
            }
        }
        _settling = false;

        delete _batchQueue[poolId];
        batchDeadline[poolId] = 0;

        emit BatchSettled(poolId, n);
    }

    /// @dev Executes one order's swap and pays out its output. External (rather than
    /// internal) only so `_settle`'s loop can wrap it in try/catch - Solidity's try/catch
    /// requires an external call. Restricted to the hook calling itself; nothing else should
    /// ever call this directly.
    function _executeOrder(PoolKey calldata key, QueuedOrder calldata order) external {
        if (msg.sender != address(this)) revert OnlySelf();

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

    /// @dev Gives back exactly the input custody an order took at queue time, in its
    /// original input currency - used when that order's real execution failed and got
    /// skipped, so the trader isn't left with tokens stuck in the hook forever.
    function _refundOrder(PoolKey memory key, QueuedOrder memory order) internal {
        Currency input = order.zeroForOne ? key.currency0 : key.currency1;
        input.settle(poolManager, address(this), order.amountIn, true);
        input.take(poolManager, order.trader, order.amountIn, false);
    }

    /// @dev Returns max(P/P0, P0/P) in Q96 fixed point, minimized at 1.0 exactly when P
    /// equals the reference price P0. This is an argmin-equivalent stand-in for the paper's
    /// (ln P0 - ln P)^2 deviation metric: minimizing |ln(P/P0)| is exactly minimizing
    /// max(P/P0, P0/P), since ln is monotonic, so picking the smallest value of this function
    /// always agrees with picking the smallest value of the paper's metric - without needing
    /// an on-chain logarithm. Comparing sqrtPriceX96 ratios directly (rather than squaring to
    /// actual price first) preserves the same ordering, since squaring is monotonic on
    /// positive reals, and avoids the overflow risk of squaring Q96 numbers.
    function _deviationFromReference(uint160 referenceSqrtPriceX96, uint160 resultingSqrtPriceX96)
        private
        pure
        returns (uint256)
    {
        if (resultingSqrtPriceX96 >= referenceSqrtPriceX96) {
            return FullMath.mulDiv(uint256(resultingSqrtPriceX96), FixedPoint96.Q96, uint256(referenceSqrtPriceX96));
        } else {
            return FullMath.mulDiv(uint256(referenceSqrtPriceX96), FixedPoint96.Q96, uint256(resultingSqrtPriceX96));
        }
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
