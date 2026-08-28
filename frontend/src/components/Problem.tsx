const steps = [
  {
    label: 'Front-run',
    title: 'Attacker buys first',
    body: 'Seeing your trade coming, someone buys the same asset right before you, pushing the price up.',
  },
  {
    label: 'Your trade',
    title: 'You buy at the worse price',
    body: 'Your trade executes exactly as intended — just at the now-inflated price the attacker created.',
  },
  {
    label: 'Back-run',
    title: 'Attacker sells for profit',
    body: 'They immediately sell back, pocketing the difference — funded entirely by your worse price.',
  },
]

export function Problem() {
  return (
    <section id="problem">
      <div className="container">
        <div className="section-head">
          <span className="eyebrow">The problem</span>
          <h2>Every large trade is a target</h2>
          <p>The instant you submit a trade, anyone watching the network can see it before it lands — and act on that split-second head start.</p>
        </div>

        <div className="flow-panel">
          <div className="flow-track">
            {steps.map((step, i) => (
              <div className="flow-step" key={step.title}>
                <div className="flow-step-top">
                  <span className="flow-step-label">{step.label}</span>
                  <span className="flow-step-num">{i + 1}</span>
                </div>
                <h4>{step.title}</h4>
                <p>{step.body}</p>
              </div>
            ))}
          </div>
          <div className="flow-line" aria-hidden="true">
            <svg viewBox="0 0 100 10" preserveAspectRatio="none">
              <path d="M0,8 Q25,1 50,5 T100,2" fill="none" stroke="currentColor" strokeWidth="0.6" />
            </svg>
          </div>
        </div>

        <p className="verdict verdict-danger">
          This is a sandwich attack — not a rare exploit, but a mechanical consequence of
          processing trades one at a time, in public, in order.
        </p>
      </div>
    </section>
  )
}
