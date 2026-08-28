import { useEffect, useState } from 'react'
import { formatUnits } from 'viem'
import { publicClient } from '../viemClient'
import { cadenceHookAbi, erc20Abi } from '../abi'
import { config, computePoolId } from '../config'

export const poolId = computePoolId()

export type TokenInfo = { symbol: string; decimals: number }

export type QueuedOrder = {
  trader: `0x${string}`
  zeroForOne: boolean
  amountIn: bigint
  blockNumber: bigint
}

export type PoolState = {
  blockNumber: bigint
  queueLength: bigint
  batchDeadline: bigint
  blocksUntilDeadline: bigint
  orders: QueuedOrder[]
}

export function useTokenInfo(address: `0x${string}`): TokenInfo | null {
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

export function usePoolState(): { state: PoolState | null; error: string | null } {
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

export function formatAmount(amount: bigint, token: TokenInfo | null): string {
  if (!token) return amount.toString()
  const formatted = Number(formatUnits(amount, token.decimals))
  return `${formatted.toLocaleString(undefined, { maximumFractionDigits: 4 })} ${token.symbol}`
}

export function truncateAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}
