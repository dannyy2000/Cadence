const steps = [
  {
    title: 'Small trades execute instantly',
    body: "Most trades aren't worth attacking — the price impact is too small to profit from. Below a size threshold, your trade runs exactly like a normal Uniswap swap. No waiting, no added cost.",
  },
  {
    title: 'Large trades join a sealed queue',
    body: "Above that threshold, your trade doesn't touch the price yet. It's pulled into a short holding window together with every other large trade — sealed off from outside interference. Nobody can insert a trade before or after yours anymore.",
  },
  {
    title: 'The window settles as one fair batch',
    body: 'Once the window closes, every trade in it clears together in a single, indivisible transaction — using CLVR, an ordering rule proven to keep every trade close to the fair market price. The order comes from that algorithm, not from any party choosing it.',
  },
  {
    title: 'Everyone settles algorithmically',
    body: "Nobody hand-picks who goes first — not the contract, not whoever happens to trigger settlement. Every trader in the batch settles the same computed way, every time.",
  },
]

export function HowItWorks() {
  return (
    <section id="how-it-works" className="section-alt">
      <div className="container">
        <div className="section-head">
          <span className="eyebrow">How it works</span>
          <h2>Sealing off the gap attackers need</h2>
          <p>Sandwich attacks depend on one thing: a visible "before" and "after" around your trade. Cadence removes both.</p>
        </div>

        <div className="timeline">
          {steps.map((step, i) => (
            <div className="timeline-item" key={step.title}>
              <div className="timeline-marker">
                <span className="timeline-num">{i + 1}</span>
              </div>
              <div className="timeline-content">
                <h3>{step.title}</h3>
                <p>{step.body}</p>
              </div>
            </div>
          ))}
        </div>

        <p className="verdict verdict-success">
          Batching stops outsiders from cutting in. CLVR makes sure the trades already sealed
          inside are treated fairly, too.
        </p>
      </div>
    </section>
  )
}
