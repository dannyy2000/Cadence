# Cadence frontend

Full product site for CadenceHook: live pool dashboard, wallet connect (EIP-6963
multi-wallet aware), and a real trade submission form wired to the actual on-chain
ERC20 → Permit2 → router approval chain — not a read-only mockup.

Live deployment: https://cadence-chi-ten.vercel.app/ (Unichain Sepolia).

## Running against a pool

1. Deploy the contracts (local anvil sequence, or use the live Unichain Sepolia
   deployment) as described in the root `MILESTONES.md`. Note the addresses each
   step prints: the hook, the two currencies, and the `V4SwapRouter` address.
2. `cp .env.example .env.local` and fill in `VITE_HOOK_ADDRESS`, `VITE_CURRENCY0`,
   `VITE_CURRENCY1`, and `VITE_ROUTER_ADDRESS` with those addresses (`.env.example`
   has notes on where each one comes from, including for Unichain Sepolia
   specifically).
3. `npm install`
4. `npm run dev` and open the printed local URL.

## What it does

- Polls `queueLength`, `batchDeadline`, `blocksUntilDeadline`, `batchThreshold`, and
  each queued order's details every `VITE_POLL_INTERVAL_MS` (default 3s), computing
  the pool's id client-side the same way `PoolIdLibrary.toId` does on-chain.
- Connects an injected wallet (EIP-6963 discovery, with a picker when more than one
  extension is installed; falls back to the legacy `window.ethereum` slot for wallets
  that don't support EIP-6963 yet), detects network mismatch, and offers a one-click
  switch/add for Unichain Sepolia.
- Submits a real trade: checks and requests the ERC20 → Permit2 and Permit2 → router
  approvals only when actually needed, then calls `swapExactTokensForTokens` with the
  connected wallet's own address encoded as the settlement beneficiary via `hookData`
  (so a batched trade's payout reaches the wallet, not the router).
- Includes a "Get test tokens" mint button, since the deployed currencies are test
  tokens with an open `mint` function specifically so anyone can try the demo without
  a faucet.

## Scripts

- `npm run dev` — local dev server
- `npm run build` — typecheck (`tsc -b`) + production build (`vite build`)
- `npm run lint` — oxlint
- `npm run preview` — serve the production build locally
