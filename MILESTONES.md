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

## Testnet deployment (Unichain Sepolia, chain 1301)

Live deployment the frontend's `.env.local` points at:

| Contract | Address |
|---|---|
| `CadenceHook` | `0x084286d682a871af6a9fc516b5fae2937f61c088` |
| Currency0 (CTA) | `0x942300837ecb871b6b015a1d60adc89a156618ff` |
| Currency1 (CTB) | `0x9deaf219a89fe8219712d8d6814f41b2d482a1e4` |

Redeployed once already, from the addresses this table originally listed, specifically to
pick up the calibrated `batchThreshold` (see the Fix 1 entry below) — a fresh hook means a
fresh CREATE2 address, so this table (and `frontend/.env.local`) needed updating rather than
being changeable in place.

Unichain Sepolia already has canonical `PoolManager`/`PositionManager`/`SwapRouter`
deployments (resolved automatically via `hookmate`'s `AddressConstants`) — the local deploy
sequence's step 2 (`00_DeployV4.s.sol`) isn't needed here. To reproduce: fund a deployer
address with Unichain Sepolia ETH (faucets: [Uniswap's
directory](https://developers.uniswap.org/docs/unichain/tools/faucets),
[QuickNode](https://faucet.quicknode.com/unichain/sepolia)), put its private key in a
gitignored `.env` at the repo root (`PRIVATE_KEY=...`), then run the same `00_DeployHook.s.sol`
→ `01_CreatePoolAndAddLiquidity.s.sol` → (optional) `03_Swap.s.sol` sequence from the local
steps above, with `--rpc-url https://sepolia.unichain.org` in place of the anvil URL and
`--private-key "$PRIVATE_KEY"` in place of anvil's default key. The public RPC occasionally
errors on the first attempt with a transient "non-archive node" fork error — a plain retry of
the same command has resolved it both times we hit it.

---

## Milestone 2 — due week two

Contracts:
- [x] Real CLVR ordering algorithm replacing the placeholder clearing rule — implemented the O(n²) greedy rule from the paper's main text (Section 4.2), not the O(n log n) reduction (Appendix G), since batch size is already gas-capped and the simpler version is far easier to verify against the paper's own proofs. Verified against a hand-derived worked example (`testCLVR_ExecutesInDeviationMinimizingOrder`) — the contract reproduces the exact expected execution order for a batch submitted in a *different* arrival order, proving it actually reorders rather than replaying arrival order.
- [ ] Invariant tests on settlement *pricing* (e.g. no order in a batch deviates from the reference price by more than X) — CLVR is in now, so this is unblocked; not yet written
- [x] Fix 1: order-splitting evasion — below-per-trade-threshold trades now accumulate cumulative same-direction volume in a rolling window (`_smallTradeWindow`, reused `batchWindowBlocks` as the window length); once cumulative volume crosses `batchThreshold`, the crossing trade gets swept into the queue even though its own size is below threshold. Tracked per-direction rather than per-address, so it also catches splitting across multiple colluding addresses, not just repeated use of one. Verified by 3 tests: cumulative crossing gets queued, window expiry resets tracking, directions tracked independently.
- [x] `batchThreshold` calibration — the flat `5e18` had been an unjustified placeholder since M1 ("tune per deployment" in a comment, never actually tuned). Replicated Zhou et al.'s [10] minimum-profitable-attack-size method (not their number, which was calibrated for 2019 mainnet gas) using our own pool and Unichain Sepolia's real observed gas price: `testSandwich_MinimumProfitableSizeSweep()` in `SandwichDemo.t.sol` sweeps trade sizes against a plain pool and finds exactly where attacker profit crosses from negative to positive. Tested at two pool sizes 10,000× apart (100e18 and 1,000,000e18) and both independently landed on the same ~0.3–0.4% of pool depth. `script/00_DeployHook.s.sol` now sets `BATCH_THRESHOLD` from that measured ratio (`35e16`, i.e. 0.35 tokens, for its 100e18/100e18 pool) instead of the old placeholder. Test-file threshold constants (`5e18` in `CadenceHook.t.sol`, the invariant suite, and `SandwichDemo.t.sol`'s own Cadence-pool tests) are deliberately left as-is and now commented as arbitrary mechanism-testing values, not production numbers, to avoid the exact ambiguity that prompted this work. Redeployed to Unichain Sepolia with the calibrated value once this was ready (see the deployment table above) - the new hook's `batchThreshold()` was read back on-chain afterward and confirmed to equal `35e16`, not just assumed from the deploy script succeeding.
- [x] Fix 2: one bad order griefing the batch — settlement's per-order swap+pay logic lives in an external `_executeOrder`, called via `try this._executeOrder(...) catch`. A failing order (e.g. a payout currency that reverts on transfer to its recipient — real, documented pattern) is caught, refunded its original input, and skipped (`OrderSkipped` event) instead of reverting the whole batch. Verified with a token that actually blacklists a recipient: confirmed the batch still settles and every other order still gets paid, and (with the try/catch temporarily disabled) confirmed the same blacklist really does take the whole settlement down without the fix.
- [x] Fix 3: unbounded settlement gas — max batch size (`maxBatchSize`, constructor param), force-settles immediately at the cap rather than waiting for the deadline. Verified by `testMaxBatchSize_ForceSettlesBeforeDeadline`.
- [x] Fix 4: reentrancy / pool-key spoofing / double-settlement guards — investigated all three concretely rather than adding boilerplate. Reentrancy was the one real gap: paying out a settled order can run external code (native ETH's `receive()`, or a nonstandard ERC20's `transfer()` hook), which could otherwise sneak a swap into the middle of an in-progress settlement at CLVR's expense. Fixed by rejecting any swap during `_settling` whose `sender` isn't the hook itself (only the hook's own internal settlement swaps have `sender == address(this)`). Pool-key spoofing and sequential/reentrant double-settlement turned out to already be closed by the existing design (poolId is a strong hash of the full key; `PoolManager.unlock` itself reverts on nested unlock calls) — documented why in code rather than adding redundant checks. Proven, not just asserted: `testReentrancy_SwapAttemptedDuringSettlementIsRejected` uses a token whose `transfer` attempts to reenter via a direct `poolManager.swap` call, and the fix was verified by temporarily disabling it and confirming the attack's behavior changed (it stopped being rejected at the hook and started reaching PoolManager's own accounting instead).
- [x] Fix 5: deterministic CLVR tie-breaking rule — went through two real iterations, not one. **v1 (exploited):** ties broke by arrival order (lower queue index wins) - deterministic, but gameable: an attacker can force an exact tie against a victim by submitting a trade of the identical size and direction, and front-running means arriving first by definition, so arrival-order tie-breaking handed the tie to the attacker every time. Verified empirically in `SandwichDemo.t.sol`: a size-matched front-run produced profit numerically identical to an unprotected plain pool. **v2 (superseded):** keyed the tie-break on `blockhash(block.number - 1)`, captured fresh at settlement time - unpredictable at submission time, still deterministic and checkable after. Verified this genuinely changed the outcome (varied across settlement blocks, including landing the attacker at a loss) - but checking the actual expected value across those outcomes showed the attack was still strongly profitable on average (≈+2,062 tokens expected value per attempt), since "unpredictable per attempt" and "unprofitable on average" are different properties. **v3 (actual fix):** exactly-tied orders (identical amountIn and direction) are no longer sequenced against each other at all - they're merged into one combined swap and the output split pro-rata, so there's no first/second position left to win or lose. Verified across all 12 tested settlement blocks in `testSandwich_CadencePool_OutcomeVariesAcrossSettlementBlocks`: the outcome is now identical every time (the block-dependent variance is eliminated entirely, not reduced), and the traced `OrderSettled` events confirm both parties settle at the same `settlementStep`, not sequentially. What this does **not** close, stated honestly: the merged pair gets an identical fair price, but a separate, smaller profit remains from timing an exit after the batch's own price impact - this is Loss-Versus-Rebalancing (cited as [1] in the README), a distinct, published, unsolved problem that exists on every AMM regardless of settlement design, not an ordering flaw. `blockhash` tie-breaking is kept as a fallback for the rarer case of two *different*-sized orders coincidentally landing on the same deviation score.
- [x] Gas benchmarking on the settlement path — `testGas_SingleOrderQueueing` (<500k gas) and `testGas_SettlementAtMaxBatchSize` (<20M gas at the 20-order cap, well under a mainnet block's ~30M limit), confirming the O(n²) CLVR cost stays practical once batch size is bounded
- [x] Broad test suite expansion — access control (`onlyPoolManager`, `_executeOrder` self-call guard), multi-pool isolation (two pools on one hook never cross-contaminate queues/deadlines), more CLVR worked examples (n=1, n=2, all-same-direction smallest-to-largest per the paper's Section 5.7 — both hand-derived and fuzzed, direction symmetry), deadline-boundary precision (one block before vs. exactly at), multiple consecutive batches, constructor-parameter fuzzing (threshold/window/max-batch-size all independently fuzzed), configuration boundaries (threshold=0, maxBatchSize=1), hookData edge cases, event-field verification, and a second reentrancy attack shape (nested `settle()` vs. nested `swap()` — rejected by `PoolManager` itself, not `CadenceHook`, but proven caught cleanly by Fix 2 either way). 68 tests total (was 28), including a 3rd invariant (`invariant_QueueNeverExceedsMaxBatchSize`) and `testSandwich_MinimumProfitableSizeSweep`, the trade-size sweep that derived the real `batchThreshold` calibration below
- [x] Live sandwich-attack demo (`test/SandwichDemo.t.sol`, ahead of schedule — originally Final-milestone work, pulled forward since it's the flagship proof and the mechanism it depends on needed to be right before building a frontend around it): the identical front-run/victim/back-run sequence against a plain pool vs. a Cadence pool. Built honestly against the paper's own definition of a "risk-free" sandwich (Appendix C) — the attacker starts with zero pre-existing inventory and can only fund their back-run with real settlement proceeds, not a convenient guess. This process is what found the Fix 5 gap above: the first, naive version of the demo (attacker and victim trading identical sizes) showed **zero protection** — profit numerically identical to the unprotected plain pool — which is what triggered fixing the tie-break rule rather than just writing up a nicer-looking result.

Frontend:
- [x] Trade submission form wired to the hook — walks the real ERC20→Permit2→router approval chain checking existing allowances first, includes a test-token mint button, previews instant-vs-queued based on the pool's real `batchThreshold`. Verified end-to-end by an actual click-through on Unichain Sepolia, not just code review: found and fixed two real bugs this surfaced that no amount of reading the code would have caught - wallet state wasn't shared across components (nav showed connected, form didn't), and the wallet client was created without a chain, which viem silently refuses to sign anything without. A real trade above threshold was submitted, both approvals confirmed, and it correctly joined the batch queue.
- [ ] Live batch visualization (orders joining, deadline countdown, settlement firing) — dashboard already shows queue size/deadline countdown from M1; still needs a real-time "order just joined" transition, not just polling snapshots
- [x] Wallet connect — injected-provider connection via plain viem, network mismatch detection with a one-click switch/add for Unichain Sepolia, auto-reconnect on return visits. Verified end-to-end alongside the trade form above. Two more real bugs found after deploying publicly, both from actual use, not code review: (1) with more than one wallet extension installed, the original single-slot (`window.ethereum`) code could only ever see whichever one won that race - fixed with proper EIP-6963 multi-wallet discovery and a picker when more than one is found; (2) auto-reconnect then failed *every* reload, not intermittently - `connect()` was trying to figure out which wallet had been used by matching object references after the fact, which can never work for the legacy-fallback case, so nothing was ever recorded to reconnect with. Fixed by having wallet resolution return an unambiguous identifying key alongside the provider, instead of guessing afterward.
- [x] Deployed to public testnet — Unichain Sepolia (chain 1301), using the network's canonical PoolManager/PositionManager/SwapRouter (no redeployment needed there - `BaseScript`/`Deployers.sol` already resolved them via `AddressConstants`). Submitted a real above-threshold swap and confirmed it actually joined the queue on-chain (`queueLength` went 0 → 1), not just that the transaction succeeded. Frontend `.env.local` points at the current deployment (see the address table above). One fix needed along the way: `ensureCurrencies()`/the constructor's currency setup only deployed fresh test tokens on chain 31337 - extended to also cover Unichain Sepolia (`_usesFreshTestTokens()`), since the template's hardcoded placeholder token addresses don't exist there. Redeployed once since the initial deployment, to pick up the calibrated `batchThreshold` - the new deployment's `batchThreshold()` was read back on-chain and confirmed to equal the calibrated `35e16`, not just assumed from the deploy script.

---

## Final submission — days after M2

- [ ] Live before/after sandwich demo: identical front-run/victim/back-run sequence against a plain pool vs. a Cadence pool, attacker profit zeroed out — rendered in the frontend
- [x] Publicly hosted — https://cadence-chi-ten.vercel.app/, deployed on Vercel. Verified the deploy itself is sound (200 response, correct build, environment variables actually baked into the compiled bundle - not just assumed from a successful build log), then found and fixed three more real bugs specifically from testing the live public deployment: an input overflow bug hiding a button behind the amount field, the multi-wallet EIP-6963 gap above, and the auto-reconnect fix above it. "Polish" is still open - this covers hosting and the bugs surfaced by actually using the hosted version, not a final look-and-feel pass.
- [ ] Team section + final README pass
- [ ] Final test/security pass
