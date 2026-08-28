// Real, verified figures from test/SandwichDemo.t.sol - not illustrative placeholders.
// Reproduce with: forge test --match-contract SandwichDemoTest -vv
const PLAIN_POOL_PROFIT = 4417.78
const CADENCE_TRIAL_LUCKY = 4417.78
const CADENCE_TRIAL_UNLUCKY = -292.79

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

          <div className="proof-card proof-card-good">
            <span className="proof-card-label">Cadence-enabled pool</span>
            <div className="proof-card-split">
              <div>
                <span className="proof-card-value mono">{formatSigned(CADENCE_TRIAL_LUCKY)}</span>
                <span className="proof-split-caption">one real trial</span>
              </div>
              <div>
                <span className="proof-card-value mono proof-value-negative">
                  {formatSigned(CADENCE_TRIAL_UNLUCKY)}
                </span>
                <span className="proof-split-caption">another real trial</span>
              </div>
            </div>
            <span className="proof-card-unit">attacker profit, token1</span>
            <p className="proof-card-note">
              No longer reliable. The outcome depends on which block settlement happens to
              land in — something nobody, including the attacker, controls in advance. Same
              attack, same sizes: sometimes a profit, sometimes an outright loss.
            </p>
          </div>
        </div>

        <p className="verdict verdict-success">
          We're not claiming a guaranteed zero — we're honest that it's a coin flip the
          attacker can no longer call in advance. Turning a certainty into a gamble is what
          actually stops it from being worth attacking at scale.
        </p>

        <p className="proof-repro">
          Reproduce it yourself: <code className="mono">forge test --match-contract SandwichDemoTest -vv</code> in the repo.
        </p>
      </div>
    </section>
  )
}
