import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react'
import { createWalletClient, custom, defineChain, type WalletClient } from 'viem'
import { config } from '../config'

// A properly-typed viem Chain, not just an object that happens to look like one - passed to
// createWalletClient below so every write knows which network it's actually submitting to.
// Without this, viem has no chain info anywhere and refuses to send anything, with an error
// that (unhelpfully) looks unrelated to "which network."
export const unichainSepolia = defineChain({
  id: 1301,
  name: 'Unichain Sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [config.rpcUrl] } },
  blockExplorers: { default: { name: 'Uniscan', url: 'https://sepolia.uniscan.xyz' } },
})

const UNICHAIN_SEPOLIA = unichainSepolia

// Minimal EIP-1193 shape - just what this file actually calls.
type InjectedProvider = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>
  on?: (event: string, handler: (...args: unknown[]) => void) => void
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void
}

// EIP-6963: lets a page discover every installed wallet extension separately, instead of all
// of them competing for the single legacy `window.ethereum` slot. That single-slot pattern is
// exactly what broke when more than one wallet extension is installed - whichever one wins
// that race is the only one the page could ever see, regardless of which one the user
// actually wants to use (this is the real bug behind "it only lets me use the Uniswap
// extension, not MetaMask" - the page was never offering a choice in the first place).
type EIP6963ProviderInfo = {
  uuid: string
  name: string
  icon: string
  rdns: string
}
type EIP6963ProviderDetail = {
  info: EIP6963ProviderInfo
  provider: InjectedProvider
}

declare global {
  interface WindowEventMap {
    'eip6963:announceProvider': CustomEvent<EIP6963ProviderDetail>
  }
  interface Window {
    ethereum?: InjectedProvider
  }
}

const LAST_WALLET_KEY = 'cadence.lastWalletRdns'
// Sentinel for "connected via the legacy window.ethereum slot, no EIP-6963 rdns available" -
// distinct from any real rdns string, so it round-trips through localStorage unambiguously.
const LEGACY_KEY = '__legacy_window_ethereum__'

export type WalletState = {
  address: `0x${string}` | null
  chainId: number | null
  connecting: boolean
  error: string | null
}

type WalletContextValue = WalletState & {
  availableWallets: EIP6963ProviderInfo[]
  hasInjectedWallet: boolean
  isCorrectChain: boolean
  targetChainId: number
  targetChainName: string
  walletClient: WalletClient | null
  connect: (rdns?: string) => Promise<void>
  disconnect: () => void
  switchToUnichainSepolia: () => Promise<void>
}

const WalletContext = createContext<WalletContextValue | null>(null)

/// Holds the one canonical wallet connection for the whole app. Every component that needs
/// wallet state reads from this same instance via useWallet() below - each component calling
/// a plain (non-context) hook independently would otherwise give every one of them its own
/// isolated, never-synced copy of "connected or not", which is exactly the bug this fixed
/// earlier: the nav's connect button and the trade form disagreeing about whether a wallet
/// was connected, because each held its own separate state.
export function WalletProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<WalletState>({
    address: null,
    chainId: null,
    connecting: false,
    error: null,
  })
  const [walletClient, setWalletClient] = useState<WalletClient | null>(null)
  const [wallets, setWallets] = useState<Map<string, EIP6963ProviderDetail>>(new Map())
  const [activeProvider, setActiveProvider] = useState<InjectedProvider | null>(null)

  // Ask every installed wallet extension to announce itself, and collect them all - rather
  // than grabbing whatever happens to be sitting at window.ethereum.
  useEffect(() => {
    const handleAnnounce = (event: CustomEvent<EIP6963ProviderDetail>) => {
      setWallets((prev) => new Map(prev).set(event.detail.info.rdns, event.detail))
    }
    window.addEventListener('eip6963:announceProvider', handleAnnounce as EventListener)
    window.dispatchEvent(new Event('eip6963:requestProvider'))
    return () => window.removeEventListener('eip6963:announceProvider', handleAnnounce as EventListener)
  }, [])

  const availableWallets = Array.from(wallets.values()).map((w) => w.info)
  const hasInjectedWallet = wallets.size > 0 || (typeof window !== 'undefined' && !!window.ethereum)

  // Resolves which provider a connect() call should use, paired with an unambiguous key
  // identifying it - an explicit choice, else the wallet used last time (if it's still
  // installed), else the only one if there's just one, else the legacy single-slot as a last
  // resort for a wallet that doesn't support EIP-6963 yet. Returning the key alongside the
  // provider (rather than trying to reverse-engineer it later by comparing object references)
  // is deliberate: the legacy window.ethereum fallback would never match any entry in the
  // `wallets` map by reference, so a lookup-after-the-fact would silently and permanently fail
  // to record it - which is exactly the bug that made every single page reload never
  // reconnect, not just an occasional one.
  const resolveProvider = useCallback(
    (rdns?: string): { provider: InjectedProvider; key: string } | null => {
      if (rdns) {
        const provider = wallets.get(rdns)?.provider
        return provider ? { provider, key: rdns } : null
      }
      const lastUsed = typeof window !== 'undefined' ? localStorage.getItem(LAST_WALLET_KEY) : null
      if (lastUsed === LEGACY_KEY && typeof window !== 'undefined' && window.ethereum) {
        return { provider: window.ethereum, key: LEGACY_KEY }
      }
      if (lastUsed && wallets.has(lastUsed)) return { provider: wallets.get(lastUsed)!.provider, key: lastUsed }
      if (wallets.size === 1) {
        const [key, detail] = Array.from(wallets.entries())[0]
        return { provider: detail.provider, key }
      }
      if (wallets.size === 0 && typeof window !== 'undefined' && window.ethereum) {
        return { provider: window.ethereum, key: LEGACY_KEY }
      }
      return null
    },
    [wallets],
  )

  const refreshChainId = useCallback(async (provider: InjectedProvider) => {
    const chainIdHex = (await provider.request({ method: 'eth_chainId' })) as string
    setState((s) => ({ ...s, chainId: parseInt(chainIdHex, 16) }))
  }, [])

  const connect = useCallback(
    async (rdns?: string) => {
      const resolved = resolveProvider(rdns)
      if (!resolved) {
        setState((s) => ({
          ...s,
          error:
            wallets.size > 1
              ? 'More than one wallet found — pick one above.'
              : 'No wallet found — install MetaMask or a similar browser wallet.',
        }))
        return
      }
      const { provider, key } = resolved
      setState((s) => ({ ...s, connecting: true, error: null }))
      try {
        const accounts = (await provider.request({ method: 'eth_requestAccounts' })) as string[]
        setActiveProvider(provider)
        const client = createWalletClient({ chain: UNICHAIN_SEPOLIA, transport: custom(provider) })
        setWalletClient(client)
        setState((s) => ({ ...s, address: accounts[0] as `0x${string}`, connecting: false }))
        if (typeof window !== 'undefined') localStorage.setItem(LAST_WALLET_KEY, key)
        await refreshChainId(provider)
      } catch (err) {
        setState((s) => ({
          ...s,
          connecting: false,
          error: err instanceof Error ? err.message : 'Connection was rejected.',
        }))
      }
    },
    [resolveProvider, refreshChainId, wallets],
  )

  const disconnect = useCallback(() => {
    setActiveProvider(null)
    setWalletClient(null)
    setState({ address: null, chainId: null, connecting: false, error: null })
  }, [])

  const switchToUnichainSepolia = useCallback(async () => {
    if (!activeProvider) return
    const chainIdHex = `0x${UNICHAIN_SEPOLIA.id.toString(16)}`
    try {
      await activeProvider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: chainIdHex }] })
    } catch (err) {
      // 4902: chain not yet added to the wallet.
      const code = (err as { code?: number })?.code
      if (code === 4902) {
        await activeProvider.request({
          method: 'wallet_addEthereumChain',
          params: [
            {
              chainId: chainIdHex,
              chainName: UNICHAIN_SEPOLIA.name,
              nativeCurrency: UNICHAIN_SEPOLIA.nativeCurrency,
              rpcUrls: UNICHAIN_SEPOLIA.rpcUrls.default.http,
              blockExplorerUrls: [UNICHAIN_SEPOLIA.blockExplorers.default.url],
            },
          ],
        })
      } else {
        throw err
      }
    }
    await refreshChainId(activeProvider)
  }, [activeProvider, refreshChainId])

  // Detects a wallet that's already connected from a previous visit (eth_accounts, unlike
  // eth_requestAccounts, never pops a prompt - it just reports the existing permission state)
  // so a returning visitor doesn't have to click Connect again every reload. Specifically
  // prefers whichever wallet was used last time, so a multi-wallet visitor doesn't get
  // silently reconnected to the wrong one. This depends on connect() having actually recorded
  // an unambiguous key for whichever provider it used (see resolveProvider's LEGACY_KEY
  // handling) - the previous version tried to reverse-engineer that key afterward by matching
  // object references, which silently failed forever whenever the legacy window.ethereum
  // fallback was used, since it can never match anything in the `wallets` map by reference.
  // That was the actual bug behind every single reload asking to reconnect, not just some.
  //
  // The short delay here is deliberate, not arbitrary: EIP-6963 discovery is asynchronous and
  // has no "every wallet has finished announcing itself" signal, so on the very first render
  // `wallets` is still empty even though window.ethereum may already be populated by whichever
  // extension happened to load first - resolveProvider() would then fall back to that one
  // specifically, which may not be the wallet actually used last time, and silently find no
  // accounts on it while the real one hadn't announced itself yet. Waiting briefly lets
  // discovery actually populate `wallets` first, so the lastUsed match in resolveProvider()
  // has something real to match against. The effect still re-runs and re-debounces every time
  // `wallets` changes (each new wallet announcing itself), via the cleanup below cancelling
  // any pending, now-stale attempt.
  useEffect(() => {
    const timer = setTimeout(() => {
      if (wallets.size === 0 && !(typeof window !== 'undefined' && window.ethereum)) return
      const resolved = resolveProvider()
      if (!resolved) return
      const { provider } = resolved
      provider
        .request({ method: 'eth_accounts' })
        .then((accounts) => {
          const list = accounts as string[]
          if (list.length > 0) {
            setActiveProvider(provider)
            const client = createWalletClient({ chain: UNICHAIN_SEPOLIA, transport: custom(provider) })
            setWalletClient(client)
            setState((s) => ({ ...s, address: list[0] as `0x${string}` }))
            refreshChainId(provider)
          }
        })
        .catch(() => {})
    }, 250)
    return () => clearTimeout(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wallets])

  useEffect(() => {
    if (!activeProvider) return

    const handleAccountsChanged = (...args: unknown[]) => {
      const accounts = args[0] as string[]
      setState((s) => ({ ...s, address: (accounts[0] as `0x${string}`) ?? null }))
    }
    const handleChainChanged = () => {
      refreshChainId(activeProvider)
    }

    activeProvider.on?.('accountsChanged', handleAccountsChanged)
    activeProvider.on?.('chainChanged', handleChainChanged)
    return () => {
      activeProvider.removeListener?.('accountsChanged', handleAccountsChanged)
      activeProvider.removeListener?.('chainChanged', handleChainChanged)
    }
  }, [activeProvider, refreshChainId])

  const isCorrectChain = state.chainId === UNICHAIN_SEPOLIA.id

  const value: WalletContextValue = {
    ...state,
    availableWallets,
    hasInjectedWallet,
    isCorrectChain,
    targetChainId: UNICHAIN_SEPOLIA.id,
    targetChainName: UNICHAIN_SEPOLIA.name,
    walletClient,
    connect,
    disconnect,
    switchToUnichainSepolia,
  }

  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>
}

export function useWallet(): WalletContextValue {
  const ctx = useContext(WalletContext)
  if (!ctx) {
    throw new Error('useWallet must be used inside <WalletProvider>')
  }
  return ctx
}
