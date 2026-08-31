import { useEffect, useMemo, useState } from 'react'
import { encodeAbiParameters, formatUnits, parseUnits, maxUint256 } from 'viem'
import { publicClient } from '../viemClient'
import { cadenceHookAbi, erc20Abi, permit2Abi, swapRouterAbi } from '../abi'
import { config } from '../config'
import { useWallet } from '../hooks/useWallet'
import { useTokenInfo } from '../hooks/usePoolState'

const poolKey = {
  currency0: config.currency0,
  currency1: config.currency1,
  fee: config.fee,
  tickSpacing: config.tickSpacing,
  hooks: config.hookAddress,
} as const

const MINT_AMOUNT = parseUnits('1000', 18)
const MAX_UINT160 = (1n << 160n) - 1n

type Step = 'idle' | 'minting' | 'approving-token' | 'approving-permit2' | 'swapping' | 'done' | 'error'

export function TradeForm() {
  const { address, isCorrectChain, walletClient } = useWallet()
  const token0 = useTokenInfo(config.currency0)
  const token1 = useTokenInfo(config.currency1)

  const [sellToken0, setSellToken0] = useState(true)
  const [amount, setAmount] = useState('10')
  const [step, setStep] = useState<Step>('idle')
  const [message, setMessage] = useState<string | null>(null)
  const [balances, setBalances] = useState<{ token0: bigint; token1: bigint } | null>(null)
  const [threshold, setThreshold] = useState<bigint | null>(null)

  const sellCurrency = sellToken0 ? config.currency0 : config.currency1
  const sellToken = sellToken0 ? token0 : token1
  const buyToken = sellToken0 ? token1 : token0

  useEffect(() => {
    publicClient
      .readContract({ address: config.hookAddress, abi: cadenceHookAbi, functionName: 'batchThreshold' })
      .then(setThreshold)
      .catch((err) => console.error('Failed to load batchThreshold', err))
  }, [])

  async function refreshBalances() {
    if (!address) return
    const [bal0, bal1] = await Promise.all([
      publicClient.readContract({ address: config.currency0, abi: erc20Abi, functionName: 'balanceOf', args: [address] }),
      publicClient.readContract({ address: config.currency1, abi: erc20Abi, functionName: 'balanceOf', args: [address] }),
    ])
    setBalances({ token0: bal0, token1: bal1 })
  }

  useEffect(() => {
    if (address && isCorrectChain) refreshBalances()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [address, isCorrectChain])

  const amountWei = useMemo(() => {
    if (!sellToken || !amount) return null
    try {
      return parseUnits(amount, sellToken.decimals)
    } catch {
      return null
    }
  }, [amount, sellToken])

  const willQueue = amountWei !== null && threshold !== null && amountWei >= threshold

  async function handleMint() {
    if (!address || !walletClient) return
    setStep('minting')
    setMessage(`Requesting 1,000 ${sellToken?.symbol ?? 'tokens'}…`)
    try {
      const hash = await walletClient.writeContract({
        account: address,
        chain: undefined,
        address: sellCurrency,
        abi: erc20Abi,
        functionName: 'mint',
        args: [address, MINT_AMOUNT],
      })
      await publicClient.waitForTransactionReceipt({ hash })
      await refreshBalances()
      setStep('idle')
      setMessage(`Minted 1,000 ${sellToken?.symbol}.`)
    } catch (err) {
      setStep('error')
      setMessage(err instanceof Error ? err.message : 'Mint failed.')
    }
  }

  async function handleTrade() {
    if (!address || !walletClient || !amountWei || !sellToken) return

    try {
      // Step 1: ERC20 -> Permit2 allowance (one-time, standard max approval).
      const erc20Allowance = await publicClient.readContract({
        address: sellCurrency,
        abi: erc20Abi,
        functionName: 'allowance',
        args: [address, config.permit2Address],
      })
      if (erc20Allowance < amountWei) {
        setStep('approving-token')
        setMessage(`Approving ${sellToken.symbol} for Permit2…`)
        const hash = await walletClient.writeContract({
          account: address,
          chain: undefined,
          address: sellCurrency,
          abi: erc20Abi,
          functionName: 'approve',
          args: [config.permit2Address, maxUint256],
        })
        await publicClient.waitForTransactionReceipt({ hash })
      }

      // Step 2: Permit2 -> router allowance (amount-scoped, with an expiration).
      const [permit2Amount, permit2Expiration] = await publicClient.readContract({
        address: config.permit2Address,
        abi: permit2Abi,
        functionName: 'allowance',
        args: [address, sellCurrency, config.routerAddress],
      })
      const nowSeconds = Math.floor(Date.now() / 1000)
      const needsPermit2Approval = permit2Amount < amountWei || permit2Expiration < nowSeconds
      if (needsPermit2Approval) {
        setStep('approving-permit2')
        setMessage('Approving the router via Permit2…')
        const oneDay = 24 * 60 * 60
        const hash = await walletClient.writeContract({
          account: address,
          chain: undefined,
          address: config.permit2Address,
          abi: permit2Abi,
          functionName: 'approve',
          // Max amount (standard practice) rather than the exact trade size, so this
          // approval covers future trades too instead of needing one per trade.
          args: [sellCurrency, config.routerAddress, MAX_UINT160, nowSeconds + oneDay],
        })
        await publicClient.waitForTransactionReceipt({ hash })
      }

      // Step 3: the actual swap. hookData carries our own address as the settlement
      // beneficiary - the router, not the wallet, is what CadenceHook sees as `sender`, so
      // without this any batched (above-threshold) trade would pay out to the router instead
      // of us.
      setStep('swapping')
      setMessage(willQueue ? 'Submitting — this trade will join the batch queue…' : 'Submitting — executes instantly…')
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600)
      const hash = await walletClient.writeContract({
        account: address,
        chain: undefined,
        address: config.routerAddress,
        abi: swapRouterAbi,
        functionName: 'swapExactTokensForTokens',
        args: [amountWei, 0n, sellToken0, poolKey, encodeAbiParameters([{ type: 'address' }], [address]), address, deadline],
      })
      await publicClient.waitForTransactionReceipt({ hash })
      await refreshBalances()

      setStep('done')
      setMessage(
        willQueue
          ? 'Order joined the batch queue — check the Live Demo section below.'
          : 'Trade executed instantly.',
      )
    } catch (err) {
      setStep('error')
      setMessage(err instanceof Error ? err.message : 'Trade failed.')
    }
  }

  const busy = step !== 'idle' && step !== 'done' && step !== 'error'

  if (!address) {
    return (
      <div className="trade-form trade-form-locked">
        <p>Connect a wallet above to try a real trade against the live pool.</p>
      </div>
    )
  }

  if (!isCorrectChain) {
    return (
      <div className="trade-form trade-form-locked">
        <p>Switch to Unichain Sepolia (top right) to trade.</p>
      </div>
    )
  }

  return (
    <div className="trade-form">
      <div className="trade-form-direction">
        <button
          className={`trade-direction-btn ${sellToken0 ? 'active' : ''}`}
          onClick={() => setSellToken0(true)}
          disabled={busy}
        >
          Sell {token0?.symbol ?? '…'}
        </button>
        <span className="trade-direction-arrow">→</span>
        <button
          className={`trade-direction-btn ${!sellToken0 ? 'active' : ''}`}
          onClick={() => setSellToken0(false)}
          disabled={busy}
        >
          Sell {token1?.symbol ?? '…'}
        </button>
      </div>

      <div className="trade-form-row">
        <input
          type="number"
          min="0"
          step="any"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          disabled={busy}
          className="trade-amount-input"
        />
        <span className="trade-amount-symbol mono">{sellToken?.symbol ?? ''}</span>
      </div>

      <div className="trade-form-meta">
        <span>
          Balance:{' '}
          <span className="mono">
            {balances && sellToken
              ? Number(formatUnits(sellToken0 ? balances.token0 : balances.token1, sellToken.decimals)).toLocaleString(
                  undefined,
                  { maximumFractionDigits: 2 },
                )
              : '—'}{' '}
            {sellToken?.symbol}
          </span>
        </span>
        <button className="trade-mint-link" onClick={handleMint} disabled={busy}>
          Get test tokens
        </button>
      </div>

      {threshold !== null && amountWei !== null && (
        <p className={`trade-preview ${willQueue ? 'trade-preview-queue' : 'trade-preview-instant'}`}>
          {willQueue
            ? `Above the ${formatUnits(threshold, sellToken?.decimals ?? 18)} ${sellToken?.symbol} threshold — this will join the batch queue.`
            : `Below the ${formatUnits(threshold, sellToken?.decimals ?? 18)} ${sellToken?.symbol} threshold — executes instantly.`}
        </p>
      )}

      <button className="btn btn-primary trade-submit" onClick={handleTrade} disabled={busy || !amountWei}>
        {busy ? message ?? 'Working…' : `Sell ${amount || '0'} ${sellToken?.symbol ?? ''} → ${buyToken?.symbol ?? ''}`}
      </button>

      {!busy && message && (
        <p className={`trade-status ${step === 'error' ? 'trade-status-error' : 'trade-status-ok'}`}>{message}</p>
      )}
    </div>
  )
}
