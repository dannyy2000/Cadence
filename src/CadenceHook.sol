// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHookEvents} from "@openzeppelin/uniswap-hooks/src/interfaces/IHookEvents.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Batches large trades into fixed-length windows instead of letting them execute
/// one at a time against the AMM curve. Settlement (the part that actually clears a batch
/// and pays out queued traders) is not implemented yet — this is the join-the-queue half
/// of the mechanism only. See MILESTONES.md.
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

    event OrderQueued(
        PoolId indexed poolId,
        address indexed trader,
        bool zeroForOne,
        uint256 amountIn,
        uint256 queuePosition,
        uint256 deadline
    );

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

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
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

        PoolId poolId = key.toId();
        Currency specified = params.zeroForOne ? key.currency0 : key.currency1;

        // Pull the full input into hook custody (as ERC-6909 claim tokens) instead of letting
        // it execute against the AMM curve. This is the mechanical core of batching: the trade
        // does not move the pool price at all until settlement processes the whole batch together.
        specified.take(poolManager, address(this), specifiedAmount, true);

        _batchQueue[poolId].push(
            QueuedOrder({
                trader: sender,
                zeroForOne: params.zeroForOne,
                amountIn: specifiedAmount,
                blockNumber: block.number
            })
        );

        if (batchDeadline[poolId] == 0) {
            batchDeadline[poolId] = block.number + batchWindowBlocks;
        }

        emit OrderQueued(
            poolId, sender, params.zeroForOne, specifiedAmount, _batchQueue[poolId].length - 1, batchDeadline[poolId]
        );

        if (params.zeroForOne) {
            emit HookSwap(PoolId.unwrap(poolId), sender, specifiedAmount.toInt128(), 0, 0, 0);
        } else {
            emit HookSwap(PoolId.unwrap(poolId), sender, 0, specifiedAmount.toInt128(), 0, 0);
        }

        // Net the specified amount to zero so the PoolManager treats this swap's input as
        // fully handled by the hook. The caller receives no output yet — that only happens
        // once settlement clears the batch.
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(specifiedAmount.toInt128(), 0), 0);
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
