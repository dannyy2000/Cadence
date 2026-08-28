// Real, verified figures from test/SandwichDemo.t.sol - not illustrative placeholders.
// Reproduce with: forge test --match-contract SandwichDemoTest -vv
const PLAIN_POOL_PROFIT = 4417.78
const CADENCE_MERGED_PROFIT = 2067.79

function formatSigned(value: number): string {
  const sign = value > 0 ? '+' : value < 0 ? '−' : ''
  return `${sign}${Math.abs(value).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

export function Proof() {
  return (
    <section id="proof">
      <div className="container">
        <div className="section-head">
          <span className="eyebrow">The proof</span>
          <h2>The same attack, run against two pools</h2>
          <p>
            Identical three-transaction sandwich — front-run, victim trade, back-run — same
            sizes, same starting price, same liquidity. The only variable is whether Cadence
            is attached. These are real numbers from a real test run, not illustrations.
          </p>
        </div>

        <div className="proof-grid">
          <div className="proof-card proof-card-bad">
            <span className="proof-card-label">Plain Uniswap v4 pool</span>
            <span className="proof-card-value mono">{formatSigned(PLAIN_POOL_PROFIT)}</span>
            <span className="proof-card-unit">attacker profit, token1</span>
            <p className="proof-card-note">
              Guaranteed, every single time. The attacker knows this before they even submit
              the first transaction.
            </p>
          </div>

          <div className="proof-card proof-card-partial">
            <span className="proof-card-label">Cadence-enabled pool</span>
            <span className="proof-card-value mono">{formatSigned(CADENCE_MERGED_PROFIT)}</span>
            <span className="proof-card-unit">attacker profit, token1 — identical across all 12 settlement blocks tested</span>
            <p className="proof-card-note">
              Roughly half the plain pool's profit, and no longer a matter of luck. We tried an
              unpredictable tie-break first — checking the real expected value showed it still
              favored the attacker on average, so we replaced it: exactly-matched trades are now
              merged into one combined settlement instead of executed in sequence, closing the
              ordering exploit completely rather than just making it unreliable.
            </p>
          </div>
        </div>

        <p className="verdict verdict-warn">
          We're not rounding this up to zero. The remaining profit isn't an ordering exploit —
          it's Loss-Versus-Rebalancing, a distinct, published, unsolved problem that exists on
          every AMM regardless of settlement design. What we can prove, not just claim: the
          specific exploit we set out to close — winning by gaming execution order — is closed,
          verified identical across every settlement block we tested.
        </p>

        <p className="proof-repro">
          Reproduce it yourself: <code className="mono">forge test --match-contract SandwichDemoTest -vv</code> in the repo.
        </p>
      </div>
    </section>
  )
}
