import { encodeAbiParameters, keccak256, type Address } from 'viem'

const env = import.meta.env

function requireEnv(key: string): string {
  const value = env[key]
  if (!value) {
    throw new Error(
      `Missing ${key} - copy frontend/.env.example to frontend/.env.local and fill in ` +
        `the addresses printed by the deploy scripts (see MILESTONES.md).`,
    )
  }
  return value
}

export const config = {
  rpcUrl: requireEnv('VITE_RPC_URL'),
  hookAddress: requireEnv('VITE_HOOK_ADDRESS') as Address,
  currency0: requireEnv('VITE_CURRENCY0') as Address,
  currency1: requireEnv('VITE_CURRENCY1') as Address,
  fee: Number(env.VITE_POOL_FEE ?? '3000'),
  tickSpacing: Number(env.VITE_POOL_TICK_SPACING ?? '60'),
  pollIntervalMs: Number(env.VITE_POLL_INTERVAL_MS ?? '3000'),
}

/// Mirrors PoolIdLibrary.toId: keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks)).
export function computePoolId(): `0x${string}` {
  const encoded = encodeAbiParameters(
    [
      { type: 'address' },
      { type: 'address' },
      { type: 'uint24' },
      { type: 'int24' },
      { type: 'address' },
    ],
    [config.currency0, config.currency1, config.fee, config.tickSpacing, config.hookAddress],
  )
  return keccak256(encoded)
}
