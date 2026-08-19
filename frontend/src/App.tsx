import { useEffect, useState } from 'react'
import { formatUnits } from 'viem'
import { publicClient } from './viemClient'
import { cadenceHookAbi, erc20Abi } from './abi'
import { config, computePoolId } from './config'
import './App.css'

const poolId = computePoolId()

type TokenInfo = { symbol: string; decimals: number }

type QueuedOrder = {
  trader: `0x${string}`
  zeroForOne: boolean
  amountIn: bigint
  blockNumber: bigint
}

type PoolState = {
  blockNumber: bigint
  queueLength: bigint
  batchDeadline: bigint
  blocksUntilDeadline: bigint
  orders: QueuedOrder[]
}

function useTokenInfo(address: `0x${string}`): TokenInfo | null {
  const [info, setInfo] = useState<TokenInfo | null>(null)

  useEffect(() => {
    let cancelled = false
    async function load() {
      const [symbol, decimals] = await Promise.all([
        publicClient.readContract({ address, abi: erc20Abi, functionName: 'symbol' }),
        publicClient.readContract({ address, abi: erc20Abi, functionName: 'decimals' }),
      ])
      if (!cancelled) setInfo({ symbol, decimals })
    }
    load().catch((err) => console.error('Failed to load token info', address, err))
    return () => {
      cancelled = true
    }
  }, [address])

  return info
}

function usePoolState(): { state: PoolState | null; error: string | null } {
  const [state, setState] = useState<PoolState | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false

    async function poll() {
      try {
        const [blockNumber, queueLength, batchDeadline, blocksUntilDeadline] = await Promise.all([
          publicClient.getBlockNumber(),
          publicClient.readContract({
            address: config.hookAddress,
            abi: cadenceHookAbi,
            functionName: 'queueLength',
            args: [poolId],
          }),
          publicClient.readContract({
            address: config.hookAddress,
            abi: cadenceHookAbi,
            functionName: 'batchDeadline',
            args: [poolId],
          }),
          publicClient.readContract({
            address: config.hookAddress,
            abi: cadenceHookAbi,
            functionName: 'blocksUntilDeadline',
            args: [poolId],
          }),
        ])

        const orders = await Promise.all(
          Array.from({ length: Number(queueLength) }, (_, index) =>
            publicClient.readContract({
              address: config.hookAddress,
              abi: cadenceHookAbi,
              functionName: 'queuedOrder',
              args: [poolId, BigInt(index)],
            }),
          ),
        )

        if (!cancelled) {
          setState({ blockNumber, queueLength, batchDeadline, blocksUntilDeadline, orders })
          setError(null)
        }
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err))
      }
    }

    poll()
    const interval = setInterval(poll, config.pollIntervalMs)
    return () => {
      cancelled = true
      clearInterval(interval)
    }
  }, [])

  return { state, error }
}

function formatAmount(amount: bigint, token: TokenInfo | null): string {
  if (!token) return amount.toString()
  const formatted = Number(formatUnits(amount, token.decimals))
  return `${formatted.toLocaleString(undefined, { maximumFractionDigits: 4 })} ${token.symbol}`
}

function truncateAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

function BatchStatus({ state }: { state: PoolState }) {
  if (state.queueLength === 0n) {
    return <span className="badge badge-idle">No batch open</span>
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

export default function App() {
  const { state, error } = usePoolState()
  const token0 = useTokenInfo(config.currency0)
  const token1 = useTokenInfo(config.currency1)

  return (
    <main className="page">
      <header>
        <h1>🎼 Cadence</h1>
        <p className="subtitle">Live batch queue — read-only view of a real local pool</p>
      </header>

      {error && (
        <div className="card card-error">
          <strong>Couldn't reach the chain.</strong>
          <p>{error}</p>
          <p className="hint">
            Is anvil running at {config.rpcUrl}? Check frontend/.env.local against the addresses
            printed by the deploy scripts.
          </p>
        </div>
      )}

      {!error && !state && <div className="card">Loading…</div>}

      {state && (
        <>
          <section className="card">
            <h2>Pool</h2>
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
          </section>

          <section className="card">
            <h2>Batch state</h2>
            <BatchStatus state={state} />
            <dl className="stats">
              <div>
                <dt>Orders queued</dt>
                <dd>{state.queueLength.toString()}</dd>
              </div>
              <div>
                <dt>Batch deadline</dt>
                <dd>{state.batchDeadline === 0n ? '—' : `block ${state.batchDeadline.toString()}`}</dd>
              </div>
            </dl>
          </section>

          <section className="card">
            <h2>Queued orders</h2>
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
          </section>
        </>
      )}
    </main>
  )
}
