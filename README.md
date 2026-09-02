<div align="center">

# 🎼 Cadence

### *A rhythm the market can't front-run.*

**A Uniswap v4 hook that batches trades into short, fixed windows and settles them using a provably fair, deviation-minimizing clearing rule — eliminating sandwich attacks and reducing LP value leakage at the source, instead of taxing or patching around them.**

![Hookathon](https://img.shields.io/badge/Hookathon-UHI10-8A2BE2?style=for-the-badge)
![Theme](https://img.shields.io/badge/Theme-Sustainable%20Liquidity%20%26%20MEV%20Protection-FF6B35?style=for-the-badge)
![Built For](https://img.shields.io/badge/Built%20for-Uniswap%20v4%20Hooks-FF007A?style=for-the-badge)
![Status](https://img.shields.io/badge/Status-Design%20Proposal-F5C518?style=for-the-badge)
![Research](https://img.shields.io/badge/Research--Backed-9%20Sources%20Cited-2E8B57?style=for-the-badge)

</div>

---

## 🧭 At a Glance

| | |
|---|---|
| 🎯 **Problem** | LPs bleed value to sandwich attacks and LVR — worst on volatile, long-tail pairs |
| ⚙️ **Mechanism** | Batch trades in short windows → settle together via CLVR fair-ordering |
| 📚 **Grounded in** | 3 core academic papers, 4 production-system precedents |
| 🛡️ **Hardened against** | 5 named, concretely-fixed attack/griefing vectors |
| 🧪 **Proof, not pitch** | Live before/after on-chain demo — no slide required |

---

## 📖 Table of Contents

1. [The Problem](#-the-problem)
2. [Theme Alignment](#-theme-alignment)
3. [The Mechanism](#-the-mechanism)
4. [Academic Foundations](#-academic-foundations)
5. [Security Analysis & Hardening](#-security-analysis--hardening)
6. [Honest Trade-offs](#-honest-trade-offs)
7. [Positioning Against Existing Work](#-positioning-against-existing-work)
8. [Demo Plan](#-demo-plan)
9. [References](#-references)
10. [Team](#-team)

---

## 🎯 The Problem

Every AMM pool is always slightly behind the real market. The instant the true price of an asset moves, the pool's own price is stale for a brief window — and someone is always fast enough to exploit that window before the pool catches up. This isn't an occasional exploit carried out by a few bad actors; it is a mechanical, structural property of processing trades one at a time, in continuous time. It happens on every price movement, on every pool, constantly.

This is what makes **sandwich attacks** possible: an attacker trades ahead of a victim's pending swap (pushing the price), lets the victim's trade execute at the now-worse price, then trades back immediately after to capture the difference. The attacker needs only one thing to make this work — a strict, sequential ordering of trades, where "before" and "after" exist as separate, observable events.

The formal cost of this dynamic to liquidity providers is captured in the literature as **Loss-Versus-Rebalancing (LVR)** [1] — the systematic loss an LP incurs because arbitrageurs trade against the pool the instant it falls out of step with the true market price. LVR scales with the *volatility of the pair's relative price*, not the absolute size of either asset:

> 📉 A calm, correlated pair like WBTC/WETH leaks comparatively little. A wild, thinly-traded pair can leak far more than any reasonable fee tier can compensate for.

This is the direct, structural reason rational liquidity providers avoid volatile pairs today — and why "sustainable liquidity for any asset pair, at low fees" does not currently hold true outside a handful of blue-chip pools.

**Cadence targets the mechanical precondition itself** — sequential, one-at-a-time trade processing — rather than taxing, delaying, or patching around its symptoms.

---

## 🏁 Theme Alignment

> **UHI10 Hookathon: Sustainable Liquidity & MEV Protection**
> *The goal here is to reduce value leakage from LPs and make volatile-pair liquidity sustainable at low fees — pushing hook innovation toward fair, MEV-protected execution that lets LPs compete on any asset pair.*

| Theme condition | How Cadence satisfies it |
|---|---|
| 💧 **Reduce value leakage from LPs** | Removes the mechanical precondition sandwich attacks depend on (sequential ordering), rather than reducing its size after the fact. Hardened against evasion (order-splitting) and against re-introducing leakage through the settlement mechanism itself (gas-cost fronting, griefing). |
| 💸 **Sustainable liquidity at low fees** | A hybrid size-threshold design means the overwhelming majority of ordinary trades pay nothing extra and experience zero added latency. Only large, batch-relevant trades — the ones actually worth attacking — carry any additional cost, and that cost is a small, proportional settlement fee, not a blanket fee hike. |
| 🛡️ **Fair, MEV-protected execution** | This *is* the mechanism, not a side effect. Batched trades settle without any exploitable "first" or "last" position. |
| 🌐 **LPs compete on any asset pair** | The batch window length is a per-pool parameter, chosen once by the pool creator at deployment. A thin, volatile pair can choose a longer window to reliably gather enough orders to net against, while a busy pair can choose a short one — the same hook code correctly serves both cases instead of being tuned for one. |

**Maps to two of Atrium's five sample hook categories:**
- 🥪 **Sandwich-Neutralizing Hooks** — the batch clearing rule directly and structurally neutralizes sandwiching.
- ⏱️ **Time-Weighted Execution Hooks** — the batch window is, by definition, a time-weighted execution window that smooths order flow.

---

## ⚙️ The Mechanism

### Core flow

```
 Order arrives ──▶ Above threshold? ──No──▶ Execute instantly (normal swap)
                          │
                         Yes
                          ▼
                  Join batch queue
                          │
              (queue was empty?) ──▶ set batchDeadline = block.number + N
                          │
              wait for next interaction after deadline
                          │
                          ▼
        Settle ALL queued orders together via CLVR ordering [3]
                          │
                          ▼
              New batch begins with the triggering order
```

1. A trade above a defined size threshold does not execute instantly. It joins a batch queue.
2. If the queue was empty, the incoming order sets `batchDeadline = block.number + N`, where `N` is a fixed number of blocks chosen **once**, by the pool's deployer, at pool creation — immutable thereafter.
3. Subsequent orders arriving before `block.number` reaches `batchDeadline` simply join the same batch.
4. Once the deadline has passed, the batch settles as a single combined calculation using the **CLVR** ordering rule [3] — every order clears together, with no trade landing strictly "before" or "after" another in a way an attacker could exploit.
5. A new batch begins immediately with whatever order triggered settlement.

### 🔔 Settlement triggering

Smart contracts cannot execute on their own — settlement can only happen as a side effect of some transaction touching the contract. Cadence uses a two-tier trigger, modeled directly on Uniswap's own **TWAMM** hook [8]:

| Path | How it works | Why it's safe |
|---|---|---|
| **Primary** (free, automatic) | The next ordinary trader who interacts with the pool after the deadline automatically triggers settlement as a mandatory first step of their own transaction. | No separate reward exists, so there's nothing to time or game. |
| **Fallback** (bounded worst case) | If the pool is quiet, *anyone* — including a trader stuck in the batch — can call a public settlement function once the deadline has passed. | Guarantees a maximum possible wait even on the quietest pairs. |

### 💰 Cost sharing

Modeled directly on **CoW Protocol's** live, production fee mechanism [5]: a small, proportional amount is deducted from **each individual order's own output** at settlement, sized to cover that order's share of the settlement cost. Whoever happens to trigger settlement is never left fronting costs on behalf of anyone else in the batch.

### 🚦 Speed / latency design — hybrid execution

- Trades **below** the size threshold execute instantly, exactly like a normal Uniswap swap. No batching, no added latency, no added cost.
- Only trades **above** the threshold join the batch queue — grounded directly in the economics of the attack itself: a sandwich attacker's profit scales with trade size, so small trades are rarely worth attacking. Protection is applied precisely where it's needed; latency is paid precisely where it's justified.

**How the threshold value itself is set — calibrated, not guessed.** Zhou, Qin, Ferreira Torres, Le & Gervais [10] show that a sandwich attack has a genuine *minimum profitable victim input*: below it, the attack costs the attacker more (gas plus the swap fee on both legs) than it extracts, so it isn't attempted at all — and their own suggested mitigation is exactly a size-threshold defense in the smart contract, which is what `batchThreshold` already is. Their empirical number (~0.3–0.5% of pool depth) was measured against 2019 Ethereum mainnet gas prices, which don't transfer to a different chain's economics — cheaper gas makes smaller attacks worthwhile, so a number borrowed from a different gas environment isn't trustworthy. Rather than reuse their number, we replicated their *method*: `test/SandwichDemo.t.sol`'s `testSandwich_MinimumProfitableSizeSweep()` runs the real attack across a range of trade sizes against our own pool, at Unichain Sepolia's actual observed gas price, and finds exactly where profit crosses from negative to positive. Tested at two pool sizes 10,000× apart (100e18 and 1,000,000e18 in reserves), both independently landed on the same ~0.3–0.4% ratio — close to, but derived independently of, the paper's own figure. `script/00_DeployHook.s.sol`'s `BATCH_THRESHOLD` is set from that measured ratio applied to the actual deployed pool's reserves, not copied from a different chain's economy. If the deployed pool's size changes, that sweep should be re-run rather than assuming the ratio still holds.

### ⏳ Batch window mechanics

- Tracked via `block.number`, **not** `block.timestamp` — `block.number` is protocol-guaranteed to increase by exactly one per block, while `block.timestamp` can be minutely influenced by whoever proposes a block.
- The deadline is a stored *target*, checked lazily the next time any transaction touches the pool — not an actively "ticking" timer, since none exists on-chain.

**How the window length itself is set — a reasoned choice, not an arbitrary one.** Budish, Cramton & Shim [2] — the frequent-batch-auctions paper batching is built on — argue that even a very short interval (their own proposal: 100ms–1s) already captures the *entire* benefit of batching over continuous-time trading. Their key finding: what eliminates the harmful "racing" dynamic is that time is discretized *at all*, not how long each discrete step is — a small speed advantage stops mattering the instant there's any gap, however small, since arriving a few milliseconds earlier inside the same interval provides no edge. By that same logic, Cadence's core protection (no external party can insert a trade before or after a batch's atomic settlement) doesn't depend on the window being long — a single order, alone in its own batch, is already just as unsandwichable as one settled alongside nine others.

That's also why Cadence's window (`batchWindowBlocks = 10`, ≈8–10 real seconds on Unichain Sepolia) is deliberately much closer to BCS's theoretical minimum than to CoW Protocol's [5] real production batches, which run roughly every ~30 seconds. That's not a contradiction between two production systems disagreeing on the right number — CoW's longer interval exists for a reason specific to *their* architecture: it has to leave enough time for a network of competing off-chain solvers to compute and submit routing solutions before a batch closes. CLVR has no equivalent step to wait on — it's a single, fast, deterministic on-chain calculation the contract runs itself the instant settlement fires — so Cadence has no structural reason to hold a batch open as long as CoW does.

**Stated honestly, not glossed over:** a short window does trade something real away. CLVR's *extra* benefit — fairly ordering *multiple* orders against each other — can only show up in practice when more than one large trade happens to land in the same short window, which will simply be rarer with a 10-block window than a longer one. The core anti-sandwich guarantee doesn't need that to happen at all, but the fuller CLVR story is more visible with more orders per batch, and a short window means fewer of them will be.

---

## 📚 Academic Foundations

Cadence is built on three papers, each doing a distinct job.

### 1️⃣ Frequent Batch Auctions — *why batching works at all*

> Budish, Cramton & Shim (2015), *"The High-Frequency Trading Arms Race: Frequent Batch Auctions as a Market Design Response"* [2]

**What it proves:** in a continuous, one-at-a-time market, mechanical arbitrage opportunities are guaranteed to exist — *even under symmetric, fully public information* — purely as a consequence of processing time continuously rather than in discrete groups. Switching to short, fixed batch windows eliminates these opportunities **by construction**, because the exploitable sliver of time between trades no longer exists as a concept.

**Role in Cadence:** this is the reason the mechanism exists at all — the proof that batching removes the *precondition* for the attack, not merely a design intuition.

### 2️⃣ CLVR Ordering — *how to settle a batch fairly and cheaply*

> *"CLVR Ordering of Transactions on AMMs"*, arXiv:2408.02634 (2024) [3]

**What it proves:** given a group of trades to settle together, there is a specific greedy ordering rule (CLVR) that approximately minimizes how far every trade's execution price deviates from the true reference price across the whole batch — cheap enough to run inside a gas-metered smart contract. The paper presents this rule (and proves its resistance to the classic 3-transaction sandwich attack) at O(n²) computational cost; a reduction to O(n log n) exists but requires a balanced-tree structure the paper only sketches at a high level (Appendix G). Cadence implements the O(n²) version — with the batch size already capped for gas-safety reasons (see the security section below), the O(n²) cost is negligible, and it's far simpler to verify against the paper's own proofs than a from-scratch tree structure would be.

**Role in Cadence:** this is the actual settlement engine — the "how" to Budish-Cramton-Shim's "why."

> ⚠️ **Known limitation, stated honestly:** CLVR's proofs are written specifically for the standard constant-product (`x·y=k`) curve, and the paper itself acknowledges that real-world Ethereum block-boundary enforcement is not something it formally specifies. Cadence's `block.number`-based, lazily-checked design is our own answer to that open question — not something the paper hands over pre-solved.

### 3️⃣ The Impossibility Result — *what we knowingly don't claim*

> Ramseyer, Goyal, Goel & Mazières, *"Augmenting Batch Exchanges with Constant Function Market Makers"*, ACM EC '24 [4]

**What it proves:** a batch exchange combined with a CFMM **cannot simultaneously guarantee** (1) full Pareto optimality for every individual order, (2) price coherence across the batch, and (3) cheap local computability. At most two of the three can hold at once.

**Role in Cadence:** this keeps the design honest. Cadence knowingly chooses **price coherence + cheap on-chain computability** (via CLVR), and does **not** claim every trader receives their individually optimal outcome. Stated explicitly, not glossed over.

---

## 🛡️ Security Analysis & Hardening

Five concrete failure modes were identified and closed. Each has real precedent — none of these are hypothetical.

<table>
<tr><td width="40">1️⃣</td><td>

**Order-splitting to evade the threshold**
**Risk:** splitting a large trade into smaller ones is a documented real strategy, measurably reducing price impact by 60–82% vs. a single large trade — an attacker could chop a trade into threshold-dodging pieces.
**Fix:** the threshold check is based on **cumulative price impact within the batch window**, not any single order's isolated size. A split trade still gets swept in once cumulative impact crosses the line. This matters more once the threshold itself is genuinely calibrated to the real minimum-profitable-attack size (see "How the threshold value itself is set" above) rather than a round guess — evading a real, tight number is worth more effort than evading an arbitrary one.

</td></tr>
<tr><td>2️⃣</td><td>

**One bad order griefing the whole batch**
**Risk:** a single order whose real execution fails — most concretely, a payout currency that reverts for a specific recipient (USDC/USDT-style address blacklisting is real and documented) — could revert the entire settlement transaction and strand every other order in the batch along with it, a documented failure pattern elsewhere in DeFi (Polymarket's "Ghost Fills").
**Fix:** each order executes in isolation (a self-call wrapped in try/catch); a failure is caught and that order is refunded its original input on its own, instead of aborting the rest of the batch. Verified with a token that reverts for one specific recipient — the other, unrelated order in the same batch still settles normally.

</td></tr>
<tr><td>3️⃣</td><td>

**Unbounded gas cost for whoever triggers settlement**
**Risk:** a batch that's grown very large before being triggered could impose an unpredictable gas cost on whoever happens to trigger it.
**Fix:** a maximum batch size is enforced — a batch force-settles at that cap or at the deadline, whichever comes first. Bounds worst-case gas exposure; busy pools settle even faster as a bonus.

</td></tr>
<tr><td>4️⃣</td><td>

**Reentrancy, pool-key spoofing, double-settlement**
**Risk:** hooks holding state across transactions are a confirmed real attack surface — this precise category has already cost DeFi a combined $11M+ across live protocols [9].
**Fix:** investigated all three concretely rather than shipping boilerplate. Reentrancy was the real gap — paying out a settled order can run external code (a nonstandard ERC20's `transfer()` hook, or native ETH's `receive()`), which could otherwise sneak its own swap into the middle of an in-progress, supposedly-atomic settlement. Closed by rejecting any swap during settlement whose `sender` isn't the hook itself. Pool-key spoofing and same-pool double-settlement turned out to already be closed by the existing design (`poolId` is a strong hash of the full pool key; `PoolManager.unlock` itself reverts on nested unlock calls) — verified, not just assumed. Proven with a token that actually attempts the reentrant swap mid-payout, confirming the attempt gets rejected. A follow-up question from an external report ([issue #1](https://github.com/dannyy2000/Cadence/issues/1)) asked specifically about the *cross-pool* case — since the settlement guard is one flag shared by every pool the hook serves, not namespaced per pool, could a payout during one pool's settlement reach a *different* pool sharing the same hook while that flag is (wrongly, from the second pool's perspective) still set? Verified this is also closed, not assumed from the single-pool proof: a dedicated test arms the malicious payout to target a second, independent pool specifically, and confirms the attempt is rejected there too, with zero effect on that pool's own state.

</td></tr>
<tr><td>5️⃣</td><td>

**CLVR ordering ambiguity**
**Risk:** if two valid orderings of a batch score identically, there's theoretical room for discretion in which one is chosen — and this isn't just theoretical: our first tie-break rule resolved ties by order of arrival, which is deterministic but exploitable, since an attacker can force a tie against a victim simply by submitting a trade of the identical size, and front-running means arriving first by definition. Verified empirically: a size-matched front-run produced profit numerically identical to an unprotected pool.
**First fix (superseded):** keying the tie-break on the settlement block's own hash — unpredictable at submission time, but still deterministic and checkable after the fact — closed the *predictability* but not the underlying problem: whoever wins an unpredictable coin flip still executes in a genuinely better position than whoever loses, because they're still executing in *sequence*. Checked the actual expected value, not just the two outcomes in isolation: with the real numbers this attack produces (≈+4,417 if the attacker wins the flip, ≈−293 if they lose), a rational attacker's expected profit across many attempts is still strongly positive — an unpredictable-per-attempt exploit is not the same thing as an unprofitable one.
**Actual fix:** when two or more queued orders tie *exactly* (identical amount and direction — which happens deterministically, not by coincidence, whenever an attacker matches a victim's trade size), they're no longer sequenced against each other at all. They're merged into one combined swap and the output is split pro-rata by contribution, so there is no "first" or "second" position left to win or lose. Verified, not just reasoned about: the same stress test now produces the *identical* result across all 12 tested settlement blocks — the block-dependent variance is gone entirely, not just reduced. What this does **not** close: the merged pair now gets an identical, fair price, but a separate profit remains from timing an exit *after* the batch's own combined price impact — a distinct, well-known, unsolved problem in the literature (Loss-Versus-Rebalancing [1]), not an ordering flaw. The blockhash tie-break is kept as a fallback for the (far rarer, and much harder to engineer deliberately) case of two *different*-sized orders coincidentally landing on the same deviation score.

</td></tr>
</table>

---

## ⚖️ Honest Trade-offs

Stated plainly, not hidden:

- 🐢 **Latency on large, batched trades is real and permanent**, not eliminated — an acknowledged, inherent property of any batching mechanism. The hybrid threshold design minimizes how often ordinary users hit it, but for trades large enough to be batched, some wait is unavoidable by design.
- ⚖️ **Full Pareto optimality for every individual trader is not guaranteed**, per the Ramseyer et al. impossibility result [4]. Cadence prioritizes price coherence and cheap on-chain computability instead — explicit, not implicit.
- 📐 **CLVR's formal guarantees are proven for the standard constant-product curve only** [3]. Extending to concentrated liquidity or alternative bonding curves isn't covered by the underlying research and would need independent verification.
- 🌙 **On genuinely quiet, thinly-traded pools**, worst-case settlement delay is bounded by the fallback path but is not instant — a real cost specifically on the volatile, long-tail pairs this project aims to help.
- 🔓 **Any pool can attach `CadenceHook` as its hook — there's no `beforeInitialize` gate or allowlist.** This is intentional, matching how Uniswap v4 hooks are generally meant to work (permissionlessly reusable, not owned by one specific pool), not an oversight. It's safe under this design specifically because every piece of hook state — the queue, the deadline, the order-splitting window — is namespaced per pool ID, and the one exception (the settlement reentrancy guard, a single flag rather than a per-pool one) was verified, not assumed, to still correctly reject a cross-pool reentrancy attempt (see Fix 4 above). A pool attaching this hook gets real batching protection for free; it can't reach into, or be reached from, any other pool sharing the same hook instance.

---

## 🗺️ Positioning Against Existing Work

Batching as a general approach to MEV protection is **not a novel category** — it's one of the more established responses in the space, and Cadence is presented with that fully acknowledged, not obscured.

| Project | Approach | Key difference from Cadence |
|---|---|---|
| **CoW Protocol** [5] | Live batch auctions at scale (~$5B/month volume, 23%+ market share) via a network of competing off-chain solvers | Cadence's cost-sharing model is directly adapted from CoW's production fee mechanism, but runs with no external solver network |
| **Angstrom** [6] | Unifies AMM liquidity and off-chain orders into uniform-price batch clearing — built inside the Uniswap Foundation's own Hook Design Lab, backed by Paradigm | Closest existing prior art. Depends on a separate off-chain network running its own dual-auction infrastructure — Cadence is fully self-contained |
| **FairTraDEX** [7] | Frequent batch auctions with formal, zero-knowledge-backed game-theoretic guarantees | A full standalone exchange protocol with ZK circuitry — Cadence trades some formal rigor for shipping as a lightweight, single hook |
| **Uniswap TWAMM** [8] | Time-windowed execution with lazy, piggyback-triggered settlement | Cadence's settlement-triggering design is directly modeled on this pattern |

> 🎯 **What differentiates Cadence is not the base concept — it's the specific, complete bundle:** CLVR's exact algorithm, wired to a named and cited economic theorem, running as a single self-contained Uniswap v4 hook with no separate off-chain network and no ZK circuitry, hardened against five concretely identified evasion and griefing vectors, with an explicit, cited statement of the one formal guarantee it does not claim. This is a claim about **depth of execution**, not about being first to the idea.

---

## 🧪 Demo Plan

The core proof is **live, not descriptive**. The same three transactions — front-run, victim swap, back-run — are executed twice, side by side:

1. 🔴 **Against a plain Uniswap v4 pool:** the attacker's wallet balance increases, every single time — this is deterministic and guaranteed, not probabilistic. In our test run: **+4,417.78** tokens, identically, every time.
2. 🟢 **Against a Cadence-enabled pool:** batching removes the mechanical precondition the plain-pool attack depends on outright. We also stress-tested the hardest case we could construct — an attacker sizing their front-run to exactly match the victim's trade — and went through two real iterations on it, not one:
   - **First fix attempt:** an unpredictable-but-deterministic tie-break. Verified it removed the *guarantee* (outcome now varied by settlement block, including an outright loss) — but checking the actual expected value across outcomes showed the attack was still strongly profitable on average, since an unpredictable coin flip isn't the same thing as an unprofitable one.
   - **Actual fix:** exactly-tied orders are no longer sequenced at all — they're merged into one combined settlement and the result is split pro-rata, so there's no "first" or "second" position left to win. Verified across all 12 tested settlement blocks: the outcome is now **identical every time** — **+2,067.79** tokens, roughly half the plain pool's guaranteed profit, with the block-dependent variance eliminated entirely, not just reduced.
   - **Stated honestly, not rounded up to zero:** that remaining +2,067.79 isn't an ordering exploit anymore — it's profit from timing an exit after the batch's own price impact, which traces to Loss-Versus-Rebalancing [1], a distinct, published, unsolved problem that exists on every AMM regardless of settlement mechanism. We're not claiming to have solved LVR; we're claiming to have closed the specific ordering exploit we set out to fix, and we can prove it (12/12 identical outcomes) rather than merely assert it.

Two on-chain transaction receipts, side by side, for both fix attempts. No slide required to make the claim credible — including for the failure modes we found while building it.

---

## 📎 References

**Academic papers:**

`[1]` Milionis, J., Moallemi, C. C., Roughgarden, T., & Zhang, A. L. (2022, rev. 2024). *Automated Market Making and Loss-Versus-Rebalancing.* arXiv:2208.06046. [https://arxiv.org/abs/2208.06046](https://arxiv.org/abs/2208.06046)

`[2]` Budish, E., Cramton, P., & Shim, J. (2015). *The High-Frequency Trading Arms Race: Frequent Batch Auctions as a Market Design Response.* The Quarterly Journal of Economics, 130(4), 1547–1621.

`[3]` *CLVR Ordering of Transactions on AMMs.* (2024). arXiv:2408.02634. [https://arxiv.org/abs/2408.02634](https://arxiv.org/abs/2408.02634)

`[4]` Ramseyer, G., Goyal, M., Goel, A., & Mazières, D. (2024). *Augmenting Batch Exchanges with Constant Function Market Makers.* ACM Conference on Economics and Computation (EC '24). arXiv:2210.04929. [https://arxiv.org/abs/2210.04929](https://arxiv.org/abs/2210.04929)

`[7]` McMenamin, C., & Daza, V. (2022). *FairTraDEX: A Decentralised Exchange Preventing Value Extraction.* arXiv:2202.06384. [https://arxiv.org/abs/2202.06384](https://arxiv.org/abs/2202.06384)

`[10]` Zhou, L., Qin, K., Ferreira Torres, C., Le, D. V., & Gervais, A. (2020). *High-Frequency Trading on Decentralized On-Chain Exchanges.* arXiv:2009.14021. [https://arxiv.org/abs/2009.14021](https://arxiv.org/abs/2009.14021)

**Production systems & technical documentation:**

`[5]` CoW Protocol Documentation. *Fair Combinatorial Batch Auction* & *Fee Model.* [https://docs.cow.fi](https://docs.cow.fi)

`[6]` Angstrom (Sorella Labs). *Batch Auction — Core Mechanisms.* [https://docs.angstrom.xyz](https://docs.angstrom.xyz)

`[8]` Uniswap Labs. *Uniswap v4 TWAMM Hook.* [https://blog.uniswap.org/v4-twamm-hook](https://blog.uniswap.org/v4-twamm-hook)

`[9]` Cyfrin & Certora. *Uniswap v4 Hooks Security Deep Dive* / *Best Practices for Writing Secure Uniswap v4 Hooks.* [https://www.cyfrin.io/blog/uniswap-v4-hooks-security-deep-dive](https://www.cyfrin.io/blog/uniswap-v4-hooks-security-deep-dive) · [https://www.certora.com/blog/best-practices-for-writing-secure-uniswap-v4-hooks](https://www.certora.com/blog/best-practices-for-writing-secure-uniswap-v4-hooks)

---

## 👥 Team

**Akinsanya Daniel** ([@dannyy2000](https://github.com/dannyy2000)) — sole builder: contracts, tests, frontend, and research.

<div align="center">

---

**Built for UHI10 · Atrium Academy**
*🎼 Cadence — a rhythm the market can't front-run.*

</div>
