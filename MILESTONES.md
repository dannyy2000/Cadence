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
- [ ] Minimal read-only scaffold connected to local/testnet pool
- [ ] Live view of pool state, batch queue size, blocks remaining until deadline

---

## Milestone 2 — due week two

Contracts:
- [ ] Real CLVR ordering algorithm replacing the placeholder clearing rule
- [ ] Invariant tests on settlement *pricing* (e.g. no order in a batch deviates from the reference price by more than X) — deferred here since testing this against the M1 placeholder algorithm would be thrown away
- [ ] Fix 1: order-splitting evasion — cumulative price-impact threshold check
- [ ] Fix 2: one bad order griefing the batch — per-order feasibility check, skip-and-refund
- [ ] Fix 3: unbounded settlement gas — max batch size, force-settle at cap
- [ ] Fix 4: reentrancy / pool-key spoofing / double-settlement guards
- [ ] Fix 5: deterministic CLVR tie-breaking rule
- [ ] Gas benchmarking on the settlement path

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
