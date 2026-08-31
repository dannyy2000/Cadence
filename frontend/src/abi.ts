export const cadenceHookAbi = [
  {
    type: 'function',
    name: 'queueLength',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'batchDeadline',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'blocksUntilDeadline',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'batchThreshold',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'batchWindowBlocks',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'queuedOrder',
    stateMutability: 'view',
    inputs: [
      { name: 'poolId', type: 'bytes32' },
      { name: 'index', type: 'uint256' },
    ],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'trader', type: 'address' },
          { name: 'zeroForOne', type: 'bool' },
          { name: 'amountIn', type: 'uint256' },
          { name: 'blockNumber', type: 'uint256' },
        ],
      },
    ],
  },
] as const

export const erc20Abi = [
  {
    type: 'function',
    name: 'symbol',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'string' }],
  },
  {
    type: 'function',
    name: 'decimals',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint8' }],
  },
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ type: 'bool' }],
  },
  // MockERC20-specific: our test tokens expose an unrestricted mint, since they exist purely
  // to let anyone try the demo without needing a token faucet. A real deployment would not
  // have this function, or would guard it.
  {
    type: 'function',
    name: 'mint',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'value', type: 'uint256' },
    ],
    outputs: [],
  },
] as const

export const permit2Abi = [
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'token', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [
      { name: 'amount', type: 'uint160' },
      { name: 'expiration', type: 'uint48' },
      { name: 'nonce', type: 'uint48' },
    ],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint160' },
      { name: 'expiration', type: 'uint48' },
    ],
    outputs: [],
  },
] as const

const poolKeyType = {
  type: 'tuple',
  name: 'poolKey',
  components: [
    { name: 'currency0', type: 'address' },
    { name: 'currency1', type: 'address' },
    { name: 'fee', type: 'uint24' },
    { name: 'tickSpacing', type: 'int24' },
    { name: 'hooks', type: 'address' },
  ],
} as const

export const swapRouterAbi = [
  {
    type: 'function',
    name: 'swapExactTokensForTokens',
    stateMutability: 'payable',
    inputs: [
      { name: 'amountIn', type: 'uint256' },
      { name: 'amountOutMin', type: 'uint256' },
      { name: 'zeroForOne', type: 'bool' },
      poolKeyType,
      { name: 'hookData', type: 'bytes' },
      { name: 'receiver', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'int256' }],
  },
] as const
