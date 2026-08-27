# Cadence — Milestones

Tracking progress against the UHI10 Hookathon submission schedule.

---

## Milestone 1 — due Sunday, Aug 23 2026

**Goal: prove the batching machinery works end-to-end, not just described.**

Contracts:
- [x] Scaffold from `v4-template` (Foundry), hook compiles and deploys locally
- [x] Threshold check in `beforeSwap`: below-threshold trades pass straight through as normal swaps
- [x] Batch queue + deadline: above-threshold trades queue up, `batchDeadline = block.number + N` set on first order in
- [x] Primary settlement trigger: next swap after deadline auto-settles the batch
- [x] Fallback settlement trigger: anyone can force settlement once the deadline has passed
- [x] Placeholder clearing rule (naive sequential settlement, atomic so it can't be externally sandwiched) — real CLVR lands in M2
- [x] Foundry tests: batch fills, deadline enforces via `block.number`, settlement auto-triggers, orders clear, fallback trigger works, opposing orders both get paid
- [x] Fuzz tests on stable logic (threshold boundary, deadline math, multi-order queueing, settlement payout, opposing orders) — 5 tests × 256 runs
- [x] Invariant tests on queue/settlement state-machine correctness (queue emptiness ⇔ no deadline; hook custody always matches what's queued) — 2 invariants × 256 runs × 500 calls, via a randomized handler

Frontend:
- [x] Minimal read-only scaffold connected to local/testnet pool (Vite + React + viem, polling directly via public RPC calls — no wallet connect, no trade submission)
- [x] Live view of pool state, batch queue size, blocks remaining until deadline — verified against a real local anvil deployment with a live queued order

---

## Local development

Reproduces the exact deployment the M1 frontend dashboard was verified against. Anvil's
default test accounts are used below — publicly known, local-only, never use them beyond this.

```bash
# 1. In one terminal: start a local chain
anvil

# 2. Deploy V4 core infra (PoolManager, PositionManager, Permit2, SwapRouter)
forge script script/testing/00_DeployV4.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# Note the three addresses it logs (Permit2 is always canonical), then export them so the
# next scripts reuse this deployment instead of each spinning up their own:
export POOL_MANAGER_ADDRESS=<V4PoolManager address>
export POSITION_MANAGER_ADDRESS=<V4PositionManager address>
export ROUTER_ADDRESS=<V4SwapRouter address>

# 3. Mine and deploy CadenceHook (address must encode its permission flags)
forge script script/00_DeployHook.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export HOOK_ADDRESS=<CadenceHook address from the broadcast output>

# 4. Deploy two test tokens (CTA/CTB), create the pool, seed it with liquidity
forge script script/01_CreatePoolAndAddLiquidity.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export CURRENCY0=<lower-sorted token address from the broadcast output>
export CURRENCY1=<higher-sorted token address from the broadcast output>

# 5. Optional: submit a real swap so there's something to see in the dashboard
forge script script/03_Swap.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 6. Point the frontend at this deployment
cd frontend
cp .env.example .env.local   # fill in VITE_HOOK_ADDRESS/VITE_CURRENCY0/VITE_CURRENCY1
npm install
npm run dev
```

Steps 3 and 4 must reuse the addresses exported in earlier steps (`POOL_MANAGER_ADDRESS`,
etc.) — each `forge script` invocation is its own process with no shared state, so without
those env vars a later script would deploy a second, disconnected set of contracts instead
of building on the first.

---

## Milestone 2 — due week two

Contracts:
- [x] Real CLVR ordering algorithm replacing the placeholder clearing rule — implemented the O(n²) greedy rule from the paper's main text (Section 4.2), not the O(n log n) reduction (Appendix G), since batch size is already gas-capped and the simpler version is far easier to verify against the paper's own proofs. Verified against a hand-derived worked example (`testCLVR_ExecutesInDeviationMinimizingOrder`) — the contract reproduces the exact expected execution order for a batch submitted in a *different* arrival order, proving it actually reorders rather than replaying arrival order.
- [ ] Invariant tests on settlement *pricing* (e.g. no order in a batch deviates from the reference price by more than X) — CLVR is in now, so this is unblocked; not yet written
- [x] Fix 1: order-splitting evasion — below-per-trade-threshold trades now accumulate cumulative same-direction volume in a rolling window (`_smallTradeWindow`, reused `batchWindowBlocks` as the window length); once cumulative volume crosses `batchThreshold`, the crossing trade gets swept into the queue even though its own size is below threshold. Tracked per-direction rather than per-address, so it also catches splitting across multiple colluding addresses, not just repeated use of one. Verified by 3 tests: cumulative crossing gets queued, window expiry resets tracking, directions tracked independently.
- [x] Fix 2: one bad order griefing the batch — settlement's per-order swap+pay logic lives in an external `_executeOrder`, called via `try this._executeOrder(...) catch`. A failing order (e.g. a payout currency that reverts on transfer to its recipient — real, documented pattern) is caught, refunded its original input, and skipped (`OrderSkipped` event) instead of reverting the whole batch. Verified with a token that actually blacklists a recipient: confirmed the batch still settles and every other order still gets paid, and (with the try/catch temporarily disabled) confirmed the same blacklist really does take the whole settlement down without the fix.
- [x] Fix 3: unbounded settlement gas — max batch size (`maxBatchSize`, constructor param), force-settles immediately at the cap rather than waiting for the deadline. Verified by `testMaxBatchSize_ForceSettlesBeforeDeadline`.
- [x] Fix 4: reentrancy / pool-key spoofing / double-settlement guards — investigated all three concretely rather than adding boilerplate. Reentrancy was the one real gap: paying out a settled order can run external code (native ETH's `receive()`, or a nonstandard ERC20's `transfer()` hook), which could otherwise sneak a swap into the middle of an in-progress settlement at CLVR's expense. Fixed by rejecting any swap during `_settling` whose `sender` isn't the hook itself (only the hook's own internal settlement swaps have `sender == address(this)`). Pool-key spoofing and sequential/reentrant double-settlement turned out to already be closed by the existing design (poolId is a strong hash of the full key; `PoolManager.unlock` itself reverts on nested unlock calls) — documented why in code rather than adding redundant checks. Proven, not just asserted: `testReentrancy_SwapAttemptedDuringSettlementIsRejected` uses a token whose `transfer` attempts to reenter via a direct `poolManager.swap` call, and the fix was verified by temporarily disabling it and confirming the attack's behavior changed (it stopped being rejected at the hook and started reaching PoolManager's own accounting instead).
- [x] Fix 5: deterministic CLVR tie-breaking rule — satisfied by construction, not extra code: the selection loop only updates `bestIndex` on a strict `<`, so on an exact deviation tie the earlier-arrived order (lower queue index) always keeps it, every time, with no discretionary choice by any party. Verified with a fixed exact-tie test and a fuzzed version across random tied amounts, not just asserted from reading the code.
- [x] Gas benchmarking on the settlement path — `testGas_SingleOrderQueueing` (<500k gas) and `testGas_SettlementAtMaxBatchSize` (<20M gas at the 20-order cap, well under a mainnet block's ~30M limit), confirming the O(n²) CLVR cost stays practical once batch size is bounded
- [x] Broad test suite expansion — access control (`onlyPoolManager`, `_executeOrder` self-call guard), multi-pool isolation (two pools on one hook never cross-contaminate queues/deadlines), more CLVR worked examples (n=1, n=2, all-same-direction smallest-to-largest per the paper's Section 5.7 — both hand-derived and fuzzed, direction symmetry), Fix 5 tie-breaking (proven deterministic, not just asserted, fixed and fuzzed), deadline-boundary precision (one block before vs. exactly at), multiple consecutive batches, constructor-parameter fuzzing (threshold/window/max-batch-size all independently fuzzed), configuration boundaries (threshold=0, maxBatchSize=1), hookData edge cases, event-field verification, and a second reentrancy attack shape (nested `settle()` vs. nested `swap()` — rejected by `PoolManager` itself, not `CadenceHook`, but proven caught cleanly by Fix 2 either way). 64 tests total (was 28), including a 3rd invariant (`invariant_QueueNeverExceedsMaxBatchSize`)

Frontend:
- [ ] Trade submission form wired to the hook
- [ ] Live batch visualization (orders joining, deadline countdown, settlement firing)
- [ ] Wallet connect, deployed to public testnet

---

## Final submission — days after M2

- [ ] Live before/after sandwich demo: identical front-run/victim/back-run sequence against a plain pool vs. a Cadence pool, attacker profit zeroed out — rendered in the frontend
- [ ] Frontend polish, publicly hosted
- [ ] Team section + final README pass
- [ ] Final test/security pass
