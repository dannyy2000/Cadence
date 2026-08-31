import { useCallback, useEffect, useState } from 'react'
import { createWalletClient, custom, type WalletClient } from 'viem'
import { config } from '../config'

const UNICHAIN_SEPOLIA = {
  id: 1301,
  name: 'Unichain Sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [config.rpcUrl] } },
  blockExplorers: { default: { name: 'Uniscan', url: 'https://sepolia.uniscan.xyz' } },
} as const

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

export function useWallet() {
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
      const client = createWalletClient({ transport: custom(window.ethereum) })
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

  return {
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
}
