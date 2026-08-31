import { useWallet } from '../hooks/useWallet'
import { truncateAddress } from '../hooks/usePoolState'

export function WalletConnect() {
  const { address, connecting, error, hasInjectedWallet, isCorrectChain, targetChainName, connect, disconnect, switchToUnichainSepolia } =
    useWallet()

  if (!hasInjectedWallet) {
    return (
      <a
        className="btn btn-secondary"
        href="https://metamask.io/download"
        target="_blank"
        rel="noreferrer"
        title="No browser wallet detected"
      >
        Get a wallet
      </a>
    )
  }

  if (!address) {
    return (
      <div className="wallet-connect">
        <button className="btn btn-primary" onClick={connect} disabled={connecting}>
          {connecting ? 'Connecting…' : 'Connect Wallet'}
        </button>
        {error && <span className="wallet-error">{error}</span>}
      </div>
    )
  }

  if (!isCorrectChain) {
    return (
      <button className="btn wallet-pill wallet-pill-warn" onClick={switchToUnichainSepolia}>
        Switch to {targetChainName}
      </button>
    )
  }

  return (
    <button className="btn wallet-pill" onClick={disconnect} title="Click to disconnect">
      <span className="wallet-dot" />
      <span className="mono">{truncateAddress(address)}</span>
    </button>
  )
}
