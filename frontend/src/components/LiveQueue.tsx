import { config } from '../config'
import {
  usePoolState,
  useRecentSettlements,
  useTokenInfo,
  formatAmount,
  truncateAddress,
  type PoolState,
  type SettlementRecord,
  type TokenInfo,
} from '../hooks/usePoolState'
import { TradeForm } from './TradeForm'

const EXPLORER_TX_URL = 'https://sepolia.uniscan.xyz/tx/'

function SettlementCard({
  settlement,
  token0,
  token1,
}: {
  settlement: SettlementRecord
  token0: TokenInfo | null
  token1: TokenInfo | null
}) {
  return (
    <div className="settlement-card">
      <div className="settlement-card-head">
        <span className="settlement-card-badge">✅ Batch settled</span>
        <span className="hint">block {settlement.blockNumber.toString()}</span>
      </div>
      <ul className="settlement-card-orders">
        {settlement.orders.map((order, i) => (
          <li key={i} className={order.skipped ? 'settlement-order-skipped' : ''}>
            <span className="mono">{truncateAddress(order.trader)}</span>
            <span>
              {order.zeroForOne
                ? `${token0?.symbol ?? 'token0'} → ${token1?.symbol ?? 'token1'}`
                : `${token1?.symbol ?? 'token1'} → ${token0?.symbol ?? 'token0'}`}
            </span>
            <span>{formatAmount(order.amountIn, order.zeroForOne ? token0 : token1)}</span>
            <span className="hint">{order.skipped ? 'skipped (refunded)' : `step ${order.settlementStep}`}</span>
          </li>
        ))}
      </ul>
      <a
        className="settlement-card-link"
        href={`${EXPLORER_TX_URL}${settlement.transactionHash}`}
        target="_blank"
        rel="noreferrer"
      >
        View this settlement on the block explorer ↗
      </a>
    </div>
  )
}

function BatchStatus({ state }: { state: PoolState }) {
  if (state.queueLength === 0n) {
    return <span className="badge badge-idle">No batch open right now</span>
  }
  if (state.blocksUntilDeadline === 0n) {
    return <span className="badge badge-due">Deadline passed — settles on next trade</span>
  }
  return (
    <span className="badge badge-open">
      Batch open — {state.blocksUntilDeadline.toString()} block
      {state.blocksUntilDeadline === 1n ? '' : 's'} until settlement
    </span>
  )
}

export function LiveQueue() {
  const { state, error } = usePoolState()
  const token0 = useTokenInfo(config.currency0)
  const token1 = useTokenInfo(config.currency1)
  const settlements = useRecentSettlements()

  return (
    <section id="live-queue">
      <div className="container">
        <div className="section-head">
          <span className="eyebrow">Live demo</span>
          <h2>Watch a real batch fill and settle</h2>
          <p>This isn't a mockup — it's polling a real Cadence pool directly on-chain, live, right now.</p>
        </div>

        <div className="browser-frame">
          <div className="browser-frame-bar">
            <span className="browser-dot browser-dot-red" />
            <span className="browser-dot browser-dot-yellow" />
            <span className="browser-dot browser-dot-green" />
            <span className="browser-frame-url mono">cadence.app/pool</span>
          </div>

          <div className="browser-frame-body">
            {error && (
              <div className="panel panel-error">
                <strong>Couldn't reach the chain.</strong>
                <p>{error}</p>
                <p className="hint">
                  Is the configured RPC ({config.rpcUrl}) reachable? Check frontend/.env.local against the
                  addresses printed by the deploy scripts.
                </p>
              </div>
            )}

            {!error && !state && <div className="panel">Loading live pool state…</div>}

            {state && (
              <div className="queue-layout">
                <div className="queue-stat-col">
                  <div className="panel">
                    <h3>Pool</h3>
                    <dl className="stats">
                      <div>
                        <dt>Pair</dt>
                        <dd>
                          {token0?.symbol ?? '…'} / {token1?.symbol ?? '…'}
                        </dd>
                      </div>
                      <div>
                        <dt>Hook</dt>
                        <dd className="mono">{truncateAddress(config.hookAddress)}</dd>
                      </div>
                      <div>
                        <dt>Current block</dt>
                        <dd>{state.blockNumber.toString()}</dd>
                      </div>
                    </dl>
                  </div>

                  <div className="panel">
                    <h3>Batch state</h3>
                    <BatchStatus state={state} />
                    <dl className="stats" style={{ marginTop: '1.25rem' }}>
                      <div>
                        <dt>Orders queued</dt>
                        <dd className="accent-num">{state.queueLength.toString()}</dd>
                      </div>
                      <div>
                        <dt>Batch deadline</dt>
                        <dd>{state.batchDeadline === 0n ? '—' : `block ${state.batchDeadline.toString()}`}</dd>
                      </div>
                    </dl>
                  </div>

                  <div className="panel">
                    <h3>Try a real trade</h3>
                    <TradeForm />
                  </div>
                </div>

                <div className="panel">
                  <h3>Queued orders</h3>
                  {state.orders.length === 0 ? (
                    <p className="hint">No large trades queued right now — try a swap above the threshold.</p>
                  ) : (
                    <table>
                      <thead>
                        <tr>
                          <th>Trader</th>
                          <th>Direction</th>
                          <th>Amount in</th>
                          <th>Joined at block</th>
                        </tr>
                      </thead>
                      <tbody>
                        {state.orders.map((order, i) => (
                          <tr key={i}>
                            <td className="mono">{truncateAddress(order.trader)}</td>
                            <td>
                              {order.zeroForOne
                                ? `${token0?.symbol ?? 'token0'} → ${token1?.symbol ?? 'token1'}`
                                : `${token1?.symbol ?? 'token1'} → ${token0?.symbol ?? 'token0'}`}
                            </td>
                            <td>{formatAmount(order.amountIn, order.zeroForOne ? token0 : token1)}</td>
                            <td>{order.blockNumber.toString()}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  )}
                </div>

                <div className="panel">
                  <h3>Recent settlements</h3>
                  {settlements.length === 0 ? (
                    <p className="hint">
                      No recent settlements yet — once a batch clears, real proof of it shows up here, not just a
                      number quietly going back to zero.
                    </p>
                  ) : (
                    <div className="settlement-list">
                      {settlements.map((settlement) => (
                        <SettlementCard
                          key={settlement.transactionHash}
                          settlement={settlement}
                          token0={token0}
                          token1={token1}
                        />
                      ))}
                    </div>
                  )}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </section>
  )
}
