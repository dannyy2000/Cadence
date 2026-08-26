// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface ISettleCallable {
    function settle(PoolKey calldata key) external;
}

/// @notice A token whose `transfer` attempts to call CadenceHook.settle() again mid-payout,
/// simulating an attacker trying to force a nested full settlement cycle rather than a bare
/// swap. This is a distinct attack shape from MaliciousReentrantToken (which calls
/// `poolManager.swap` directly): `settle` itself calls `poolManager.unlock`, which should be
/// rejected outright by PoolManager's own AlreadyUnlocked guard, independent of anything
/// CadenceHook does. Proves that rejection gets caught by Fix 2's per-order try/catch rather
/// than propagating and reverting the whole batch.
contract SettleReentrantToken is MockERC20 {
    ISettleCallable public hook;
    PoolKey public attackPoolKey;
    bool public attackArmed;
    bool public reentryAttempted;
    bool public reentryReverted;

    constructor(string memory name, string memory symbol, uint8 decimals) MockERC20(name, symbol, decimals) {}

    function arm(ISettleCallable _hook, PoolKey memory _poolKey) external {
        hook = _hook;
        attackPoolKey = _poolKey;
        attackArmed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attackArmed && !reentryAttempted) {
            reentryAttempted = true;
            try hook.settle(attackPoolKey) {
                // If this succeeds, PoolManager's nested-unlock protection failed.
            } catch {
                reentryReverted = true;
            }
        }
        return super.transfer(to, amount);
    }
}
