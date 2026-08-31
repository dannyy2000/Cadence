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

declare global {
  interface Window {
    ethereum?: {
      request: (args: { method: string; params?: unknown[] }) => Promise<unknown>
      on: (event: string, handler: (...args: unknown[]) => void) => void
      removeListener: (event: string, handler: (...args: unknown[]) => void) => void
    }
  }
}

export type WalletState = {
  address: `0x${string}` | null
  chainId: number | null
  connecting: boolean
  error: string | null
}

type WalletContextValue = WalletState & {
  hasInjectedWallet: boolean
  isCorrectChain: boolean
  targetChainId: number
  targetChainName: string
  walletClient: WalletClient | null
  connect: () => Promise<void>
  disconnect: () => void
  switchToUnichainSepolia: () => Promise<void>
}

const WalletContext = createContext<WalletContextValue | null>(null)

/// Holds the one canonical wallet connection for the whole app. Every component that needs
/// wallet state reads from this same instance via useWallet() below - each component calling
/// a plain (non-context) hook independently would otherwise give every one of them its own
/// isolated, never-synced copy of "connected or not", which is exactly the bug this fixes:
/// the nav's connect button and the trade form disagreeing about whether a wallet was
/// connected, because each held its own separate state.
export function WalletProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<WalletState>({
    address: null,
    chainId: null,
    connecting: false,
    error: null,
  })
  const [walletClient, setWalletClient] = useState<WalletClient | null>(null)

  const hasInjectedWallet = typeof window !== 'undefined' && !!window.ethereum

  const refreshChainId = useCallback(async () => {
    if (!window.ethereum) return
    const chainIdHex = (await window.ethereum.request({ method: 'eth_chainId' })) as string
    setState((s) => ({ ...s, chainId: parseInt(chainIdHex, 16) }))
  }, [])

  const connect = useCallback(async () => {
    if (!window.ethereum) {
      setState((s) => ({ ...s, error: 'No wallet found — install MetaMask or a similar browser wallet.' }))
      return
    }
    setState((s) => ({ ...s, connecting: true, error: null }))
    try {
      const accounts = (await window.ethereum.request({ method: 'eth_requestAccounts' })) as string[]
      const client = createWalletClient({ chain: UNICHAIN_SEPOLIA, transport: custom(window.ethereum) })
      setWalletClient(client)
      setState((s) => ({ ...s, address: accounts[0] as `0x${string}`, connecting: false }))
      await refreshChainId()
    } catch (err) {
      setState((s) => ({
        ...s,
        connecting: false,
        error: err instanceof Error ? err.message : 'Connection was rejected.',
      }))
    }
  }, [refreshChainId])

  const disconnect = useCallback(() => {
    setWalletClient(null)
    setState({ address: null, chainId: null, connecting: false, error: null })
  }, [])

  const switchToUnichainSepolia = useCallback(async () => {
    if (!window.ethereum) return
    const chainIdHex = `0x${UNICHAIN_SEPOLIA.id.toString(16)}`
    try {
      await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: chainIdHex }] })
    } catch (err) {
      // 4902: chain not yet added to the wallet.
      const code = (err as { code?: number })?.code
      if (code === 4902) {
        await window.ethereum.request({
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
    await refreshChainId()
  }, [refreshChainId])

  // Detects a wallet that's already connected from a previous visit (eth_accounts, unlike
  // eth_requestAccounts, never pops a prompt - it just reports the existing permission state)
  // so a returning visitor doesn't have to click Connect again every reload.
  useEffect(() => {
    if (!window.ethereum) return
    window.ethereum
      .request({ method: 'eth_accounts' })
      .then((accounts) => {
        const list = accounts as string[]
        if (list.length > 0) {
          const client = createWalletClient({ chain: UNICHAIN_SEPOLIA, transport: custom(window.ethereum!) })
          setWalletClient(client)
          setState((s) => ({ ...s, address: list[0] as `0x${string}` }))
          refreshChainId()
        }
      })
      .catch(() => {})
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (!window.ethereum) return

    const handleAccountsChanged = (...args: unknown[]) => {
      const accounts = args[0] as string[]
      setState((s) => ({ ...s, address: (accounts[0] as `0x${string}`) ?? null }))
    }
    const handleChainChanged = () => {
      refreshChainId()
    }

    window.ethereum.on('accountsChanged', handleAccountsChanged)
    window.ethereum.on('chainChanged', handleChainChanged)
    return () => {
      window.ethereum?.removeListener('accountsChanged', handleAccountsChanged)
      window.ethereum?.removeListener('chainChanged', handleChainChanged)
    }
  }, [refreshChainId])

  const isCorrectChain = state.chainId === UNICHAIN_SEPOLIA.id

  const value: WalletContextValue = {
    ...state,
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
