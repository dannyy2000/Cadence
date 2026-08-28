export function Footer() {
  return (
    <footer className="footer">
      <div className="container footer-inner">
        <span className="footer-brand">🎼 Cadence</span>
        <ul className="footer-links">
          <li>
            <a href="https://github.com/dannyy2000/Cadence" target="_blank" rel="noreferrer">
              GitHub
            </a>
          </li>
          <li>
            <a href="https://github.com/dannyy2000/Cadence/blob/main/README.md" target="_blank" rel="noreferrer">
              Design doc
            </a>
          </li>
          <li>
            <a href="https://github.com/dannyy2000/Cadence/blob/main/MILESTONES.md" target="_blank" rel="noreferrer">
              Milestones
            </a>
          </li>
        </ul>
        <p className="footer-note">
          Built for UHI10 · Atrium Academy. A design proposal, not audited — see the FAQ before
          using it with real funds.
        </p>
      </div>
    </footer>
  )
}
