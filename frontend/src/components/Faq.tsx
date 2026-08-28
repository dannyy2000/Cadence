import { useState } from 'react'

const faqs = [
  {
    q: 'Is my trade safe while it sits in the queue?',
    a: "Yes. Your tokens are held by the contract itself, not by any other trader, and nobody can touch or redirect them. They're simply waiting to settle together with the rest of the batch instead of executing alone.",
  },
  {
    q: 'Why do only large trades wait?',
    a: "Because only large trades are worth attacking. A sandwich attacker's profit comes from how much a trade moves the price — a small trade barely moves it at all, so there's nothing to exploit. Protecting it would only add delay with no benefit, so small trades execute instantly, exactly like a normal swap.",
  },
  {
    q: 'What if nobody settles the batch?',
    a: 'There are two ways a batch settles: automatically, as a side effect of the next trade on the pool once the window closes, or — if the pool goes quiet — anyone at all, including a trader stuck in the queue, can trigger settlement manually. Either way, there is a hard upper bound on how long a trade can wait.',
  },
  {
    q: "What is CLVR, and why not just process the queue in the order trades arrived?",
    a: "Processing strictly in arrival order would just move the exploitable 'before/after' gap inside the batch instead of removing it. CLVR is an academic ordering rule that instead picks whichever order keeps every trade's price closest to fair market value — proven to eliminate the classic 3-transaction sandwich pattern.",
  },
  {
    q: 'Does this slow down everyday trading?',
    a: "No. The threshold is specifically tuned so the overwhelming majority of ordinary trades never touch the queue at all — they execute exactly as fast as a normal swap, with zero added cost.",
  },
  {
    q: 'Is this audited or ready for real funds?',
    a: 'No — Cadence is a hookathon project, currently deployed to testnet only. It is thoroughly tested (including fuzz and invariant testing) and openly documents its own known limitations, but it has not undergone a professional security audit and should not be used with real funds.',
  },
]

export function Faq() {
  const [openIndex, setOpenIndex] = useState<number | null>(0)

  return (
    <section id="faq" className="section-alt">
      <div className="container">
        <div className="section-head">
          <span className="eyebrow">FAQ</span>
          <h2>Questions people actually ask</h2>
        </div>

        <div className="faq-list">
          {faqs.map((item, i) => {
            const open = openIndex === i
            return (
              <div className={`faq-item${open ? ' open' : ''}`} key={item.q}>
                <button
                  type="button"
                  className="faq-question"
                  aria-expanded={open}
                  onClick={() => setOpenIndex(open ? null : i)}
                >
                  <span>{item.q}</span>
                  <span className="faq-icon" aria-hidden="true">
                    +
                  </span>
                </button>
                {open && <div className="faq-answer">{item.a}</div>}
              </div>
            )
          })}
        </div>
      </div>
    </section>
  )
}
