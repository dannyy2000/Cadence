import { config } from '../config'
import { usePoolState, useTokenInfo, formatAmount, truncateAddress } from '../hooks/usePoolState'

function HeroPreview() {
  const { state, error } = usePoolState()
  const token0 = useTokenInfo(config.currency0)
  const token1 = useTokenInfo(config.currency1)

  if (error) {
    return (
      <div className="hero-preview">
        <div className="hero-preview-bar">
          <span className="live-dot live-dot-off" />
          <span>offline</span>
        </div>
        <p className="hint" style={{ padding: '1.5rem' }}>
          Can't reach the chain right now — see the live demo section below for details.
        </p>
      </div>
    )
  }

  return (
    <div className="hero-preview">
      <div className="hero-preview-bar">
        <span className="live-dot" />
        <span>live · block {state ? state.blockNumber.toString() : '…'}</span>
      </div>
      <div className="hero-preview-body">
        <div className="hero-preview-stat">
          <span className="hero-preview-label">Orders queued</span>
          <span className="hero-preview-value accent-num">{state ? state.queueLength.toString() : '—'}</span>
        </div>
        <div className="hero-preview-stat">
          <span className="hero-preview-label">Settles in</span>
          <span className="hero-preview-value">
            {state && state.blocksUntilDeadline > 0n
              ? `${state.blocksUntilDeadline.toString()} block${state.blocksUntilDeadline === 1n ? '' : 's'}`
              : '—'}
          </span>
        </div>
        {state && state.orders[0] && (
          <div className="hero-preview-row mono">
            <span>{truncateAddress(state.orders[0].trader)}</span>
            <span>{formatAmount(state.orders[0].amountIn, state.orders[0].zeroForOne ? token0 : token1)}</span>
          </div>
        )}
      </div>
    </div>
  )
}

export function Hero() {
  return (
    <header className="hero">
      <div className="hero-glow" aria-hidden="true" />
      <div className="container hero-grid">
        <div className="hero-copy">
          <span className="eyebrow">Uniswap v4 Hook · UHI10 Hookathon</span>
          <h1>
            A rhythm <span className="highlight">the market can't front-run.</span>
          </h1>
          <p className="hero-sub">
            Cadence batches large trades into short windows and settles them together, fairly —
            so sandwich attacks can't happen, and liquidity providers stop bleeding value to the
            split-second gap that makes them possible.
          </p>
          <div className="hero-actions">
            <a className="btn btn-primary" href="#live-queue">
              See it live
            </a>
            <a className="btn btn-secondary" href="#how-it-works">
              How it works
            </a>
          </div>
          <div className="hero-badges">
            <span className="pill">Zero cost for everyday trades</span>
            <span className="pill">Provably fair settlement</span>
            <span className="pill">No off-chain network</span>
          </div>
        </div>

        <div className="hero-visual">
          <HeroPreview />
        </div>
      </div>
    </header>
  )
}
