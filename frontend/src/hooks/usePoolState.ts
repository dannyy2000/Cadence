import { useEffect, useRef, useState } from 'react'
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

export type SettledOrder = {
  trader: `0x${string}`
  zeroForOne: boolean
  amountIn: bigint
  settlementStep: bigint
  skipped: boolean
}

export type SettlementRecord = {
  blockNumber: bigint
  transactionHash: `0x${string}`
  ordersSettled: bigint
  orders: SettledOrder[]
}

// How far back to look for settlement history on first load - generous enough to catch a
// whole recent testing/recording session, conservative enough not to risk hitting a public
// RPC's max eth_getLogs block-range limit on that first, larger query. Every poll after the
// first only asks for the small range since the last one actually checked.
const SETTLEMENT_LOOKBACK_BLOCKS = 1500n
const MAX_SETTLEMENTS_SHOWN = 5

/// @notice The queue/deadline numbers usePoolState polls prove a batch is *open* - they say
/// nothing about whether a settlement actually happened, since a settled batch just looks
/// like "queue is empty" again, indistinguishable from "nothing was ever queued." This
/// watches the hook's own BatchSettled/OrderSettled/OrderSkipped events instead - the only
/// real, on-chain proof that a settlement genuinely occurred, and exactly what it did.
export function useRecentSettlements(): SettlementRecord[] {
  const [settlements, setSettlements] = useState<SettlementRecord[]>([])
  const lastCheckedBlockRef = useRef<bigint | null>(null)

  useEffect(() => {
    let cancelled = false

    async function poll() {
      const currentBlock = await publicClient.getBlockNumber()
      const fromBlock =
        lastCheckedBlockRef.current !== null
          ? lastCheckedBlockRef.current + 1n
          : currentBlock > SETTLEMENT_LOOKBACK_BLOCKS
            ? currentBlock - SETTLEMENT_LOOKBACK_BLOCKS
            : 0n

      if (fromBlock > currentBlock) return

      try {
        const [batchSettledLogs, orderSettledLogs, orderSkippedLogs] = await Promise.all([
          publicClient.getContractEvents({
            address: config.hookAddress,
            abi: cadenceHookAbi,
            eventName: 'BatchSettled',
            args: { poolId },
            fromBlock,
            toBlock: currentBlock,
          }),
          publicClient.getContractEvents({
            address: config.hookAddress,
            abi: cadenceHookAbi,
            eventName: 'OrderSettled',
            args: { poolId },
            fromBlock,
            toBlock: currentBlock,
          }),
          publicClient.getContractEvents({
            address: config.hookAddress,
            abi: cadenceHookAbi,
            eventName: 'OrderSkipped',
            args: { poolId },
            fromBlock,
            toBlock: currentBlock,
          }),
        ])

        // A successful settlement's OrderSettled/OrderSkipped events land in the exact same
        // transaction as its one BatchSettled event - grouping by transaction hash is what
        // actually reconstructs "this settlement did these specific things," not just "a
        // settlement happened at some point."
        const newRecords: SettlementRecord[] = batchSettledLogs.map((log) => {
          const txHash = log.transactionHash as `0x${string}`
          const settledInTx = orderSettledLogs
            .filter((l) => l.transactionHash === txHash)
            .map((l) => ({
              trader: l.args.trader as `0x${string}`,
              zeroForOne: l.args.zeroForOne as boolean,
              amountIn: l.args.amountIn as bigint,
              settlementStep: l.args.settlementStep as bigint,
              skipped: false,
            }))
          const skippedInTx = orderSkippedLogs
            .filter((l) => l.transactionHash === txHash)
            .map((l) => ({
              trader: l.args.trader as `0x${string}`,
              zeroForOne: l.args.zeroForOne as boolean,
              amountIn: l.args.amountIn as bigint,
              settlementStep: l.args.settlementStep as bigint,
              skipped: true,
            }))

          return {
            blockNumber: log.blockNumber as bigint,
            transactionHash: txHash,
            ordersSettled: log.args.ordersSettled as bigint,
            orders: [...settledInTx, ...skippedInTx].sort((a, b) =>
              a.settlementStep === b.settlementStep ? 0 : a.settlementStep < b.settlementStep ? -1 : 1,
            ),
          }
        })

        lastCheckedBlockRef.current = currentBlock

        if (!cancelled && newRecords.length > 0) {
          setSettlements((prev) => [...newRecords.reverse(), ...prev].slice(0, MAX_SETTLEMENTS_SHOWN))
        }
      } catch (err) {
        // Leave lastCheckedBlockRef unmoved so the next poll retries this same range,
        // instead of silently skipping past whatever it failed to fetch.
        console.error('Failed to poll settlement events', err)
      }
    }

    poll()
    const interval = setInterval(poll, config.pollIntervalMs)
    return () => {
      cancelled = true
      clearInterval(interval)
    }
  }, [])

  return settlements
}

export function formatAmount(amount: bigint, token: TokenInfo | null): string {
  if (!token) return amount.toString()
  const formatted = Number(formatUnits(amount, token.decimals))
  return `${formatted.toLocaleString(undefined, { maximumFractionDigits: 4 })} ${token.symbol}`
}

export function truncateAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}
