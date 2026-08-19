import { createPublicClient, http } from 'viem'
import { config } from './config'

export const publicClient = createPublicClient({
  transport: http(config.rpcUrl),
})
