import { useState } from 'react'
import { useWallet } from '../context/WalletContext'
import { truncateAddress } from '../hooks/usePoolState'

export function WalletConnect() {
  const {
    address,
    availableWallets,
    chainId,
    connecting,
    error,
    hasInjectedWallet,
    isCorrectChain,
    targetChainId,
    targetChainName,
    connect,
    disconnect,
    switchToUnichainSepolia,
  } = useWallet()
  const [pickerOpen, setPickerOpen] = useState(false)

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
    // More than one wallet extension installed - let the user pick which one, instead of
    // silently grabbing whichever one happened to win the legacy window.ethereum slot.
    if (availableWallets.length > 1) {
      return (
        <div className="wallet-connect wallet-picker-wrap">
          <button className="btn btn-primary" onClick={() => setPickerOpen((v) => !v)} disabled={connecting}>
            {connecting ? 'Connecting…' : 'Connect Wallet'}
          </button>
          {pickerOpen && (
            <div className="wallet-picker">
              {availableWallets.map((wallet) => (
                <button
                  key={wallet.rdns}
                  className="wallet-picker-option"
                  onClick={() => {
                    setPickerOpen(false)
                    connect(wallet.rdns)
                  }}
                >
                  <img src={wallet.icon} alt="" className="wallet-picker-icon" />
                  {wallet.name}
                </button>
              ))}
            </div>
          )}
          {error && <span className="wallet-error">{error}</span>}
        </div>
      )
    }

    return (
      <div className="wallet-connect">
        <button className="btn btn-primary" onClick={() => connect()} disabled={connecting}>
          {connecting ? 'Connecting…' : 'Connect Wallet'}
        </button>
        {error && <span className="wallet-error">{error}</span>}
      </div>
    )
  }

  if (!isCorrectChain) {
    return (
      <div className="wallet-connect">
        <button
          className="btn wallet-pill wallet-pill-warn"
          onClick={switchToUnichainSepolia}
          title={`Wallet reports chain ${chainId ?? 'unknown'}, need ${targetChainId}`}
        >
          Switch to {targetChainName}
        </button>
        <span className="wallet-error mono">
          detected: {chainId ?? '…'} (need {targetChainId})
        </span>
      </div>
    )
  }

  return (
    <button className="btn wallet-pill" onClick={disconnect} title="Click to disconnect">
      <span className="wallet-dot" />
      <span className="mono">{truncateAddress(address)}</span>
    </button>
  )
}
