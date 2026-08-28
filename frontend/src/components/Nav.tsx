export function Nav() {
  return (
    <nav className="nav">
      <div className="nav-inner">
        <div className="nav-brand">
          <span className="nav-brand-mark">🎼</span>
          <span>Cadence</span>
        </div>
        <ul className="nav-links">
          <li>
            <a href="#problem">The problem</a>
          </li>
          <li>
            <a href="#how-it-works">How it works</a>
          </li>
          <li>
            <a href="#proof">The proof</a>
          </li>
          <li>
            <a href="#live-queue">Live demo</a>
          </li>
          <li>
            <a href="#faq">FAQ</a>
          </li>
        </ul>
        <a
          className="btn btn-secondary"
          href="https://github.com/dannyy2000/Cadence"
          target="_blank"
          rel="noreferrer"
        >
          GitHub
        </a>
      </div>
    </nav>
  )
}
