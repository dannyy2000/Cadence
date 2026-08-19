# Cadence frontend

Minimal read-only dashboard: polls a `CadenceHook` deployment directly via `viem` and shows
the live batch queue for one pool — no wallet connect, no trade submission (that's M2).

## Running against a local pool

1. From the repo root, run the local deploy sequence (anvil + the four scripts under
   `script/`) as described in `MILESTONES.md`. Note the addresses each step prints:
   `POOL_MANAGER_ADDRESS`, `HOOK_ADDRESS`, and the two token addresses used as
   `CURRENCY0`/`CURRENCY1`.
2. `cp .env.example .env.local` and fill in `VITE_HOOK_ADDRESS`, `VITE_CURRENCY0`,
   `VITE_CURRENCY1` with those addresses.
3. `npm install`
4. `npm run dev` and open the printed local URL.

The page polls `queueLength`, `batchDeadline`, `blocksUntilDeadline`, and each queued
order's details every `VITE_POLL_INTERVAL_MS` (default 3s), computing the pool's id
client-side the same way `PoolIdLibrary.toId` does on-chain.
