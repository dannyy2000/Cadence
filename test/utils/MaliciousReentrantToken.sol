// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice A token whose `transfer` attempts to reenter the pool mid-transfer, simulating a
/// nonstandard ERC20 with a transfer hook (the same real-world category as ERC777) rather
/// than an idealized token that never runs external code. Used to prove CadenceHook actually
/// rejects a swap attempted while its own settlement is mid-flight, instead of merely
/// asserting the guard code looks right.
///
/// Calls `poolManager.swap` directly rather than through a router: going through a router
/// would re-enter `PoolManager.unlock`, which already reverts on its own (nested unlocks
/// aren't allowed) regardless of anything CadenceHook does. A direct `swap` call is the
/// realistic version of this attack - nested `swap` calls within an already-unlocked context
/// are ordinary, expected usage (it's how CadenceHook's own settlement loop works) - so this
/// is what actually exercises the `sender != address(this)` guard in `_beforeSwap`.
contract MaliciousReentrantToken is MockERC20 {
    IPoolManager public poolManager;
    PoolKey public attackPoolKey;
    bool public attackArmed;
    bool public reentryAttempted;
    bool public reentryReverted;

    constructor(string memory name, string memory symbol, uint8 decimals) MockERC20(name, symbol, decimals) {}

    function arm(IPoolManager _poolManager, PoolKey memory _poolKey) external {
        poolManager = _poolManager;
        attackPoolKey = _poolKey;
        attackArmed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attackArmed && !reentryAttempted) {
            reentryAttempted = true;
            try poolManager.swap(
                attackPoolKey,
                SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                bytes("")
            ) {
                // If this succeeds, the reentrancy guard failed to block it.
            } catch {
                reentryReverted = true;
            }
        }
        return super.transfer(to, amount);
    }
}
