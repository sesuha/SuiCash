/**
 * @suicash/chain: chain configuration and viem clients.
 *
 * SuiCash is testnet only (handbook rule 3). resolveChain refuses every chain
 * except Base Sepolia and the local anvil chain, so a misconfigured
 * environment cannot point the app at mainnet.
 */
import {
  createPublicClient,
  getAddress,
  http,
  isAddress,
  type Address,
  type Chain,
  type PublicClient,
} from "viem";
import { anvil, baseSepolia } from "viem/chains";

export * from "./abis.ts";

export const BASE_SEPOLIA_CHAIN_ID = 84532;
export const ANVIL_CHAIN_ID = 31337;

/** Circle test USDC on Base Sepolia. */
export const BASE_SEPOLIA_USDC: Address = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";

const SUPPORTED_CHAINS: Readonly<Record<number, Chain>> = {
  [BASE_SEPOLIA_CHAIN_ID]: baseSepolia,
  [ANVIL_CHAIN_ID]: anvil,
};

export function resolveChain(chainId: number): Chain {
  const chain = SUPPORTED_CHAINS[chainId];
  if (!chain) {
    throw new Error(
      `Unsupported chain ID ${chainId}. SuiCash runs only on Base Sepolia (${BASE_SEPOLIA_CHAIN_ID}) or local anvil (${ANVIL_CHAIN_ID}).`,
    );
  }
  return chain;
}

export interface ChainConfig {
  chain: Chain;
  rpcUrl: string;
  bundlerUrl: string | null;
  paymasterUrl: string | null;
  usdc: Address | null;
  vaultFactory: Address | null;
  savingsPool: Address | null;
}

/** The VITE_* variables listed in .env.example. */
export type ChainEnv = Readonly<Partial<Record<string, string | undefined>>>;

function optionalUrl(env: ChainEnv, key: string): string | null {
  const value = env[key]?.trim();
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("bad protocol");
  } catch {
    throw new Error(`${key} is not a valid http(s) URL: ${value}`);
  }
  return value;
}

function optionalAddress(env: ChainEnv, key: string): Address | null {
  const value = env[key]?.trim();
  if (!value) return null;
  if (!isAddress(value, { strict: false })) {
    throw new Error(`${key} is not a valid address: ${value}`);
  }
  return getAddress(value);
}

/** Parses and validates the chain-related environment variables. Throws on any invalid value. */
export function parseChainConfig(env: ChainEnv): ChainConfig {
  const rawChainId = env["VITE_CHAIN_ID"]?.trim();
  if (!rawChainId || !/^\d+$/.test(rawChainId)) {
    throw new Error(`VITE_CHAIN_ID must be a number, got: ${rawChainId ?? "(unset)"}`);
  }
  const chain = resolveChain(Number(rawChainId));
  const rpcUrl = optionalUrl(env, "VITE_RPC_URL") ?? chain.rpcUrls.default.http[0];
  if (!rpcUrl) throw new Error("VITE_RPC_URL is not set and the chain has no default RPC URL");

  return {
    chain,
    rpcUrl,
    bundlerUrl: optionalUrl(env, "VITE_BUNDLER_URL"),
    paymasterUrl: optionalUrl(env, "VITE_PAYMASTER_URL"),
    usdc: optionalAddress(env, "VITE_USDC_ADDRESS"),
    vaultFactory: optionalAddress(env, "VITE_VAULT_FACTORY_ADDRESS"),
    savingsPool: optionalAddress(env, "VITE_SAVINGS_POOL_ADDRESS"),
  };
}

/** A read-only client for chain reads and simulation. It never holds a key. */
export function createReadClient(config: Pick<ChainConfig, "chain" | "rpcUrl">): PublicClient {
  return createPublicClient({ chain: config.chain, transport: http(config.rpcUrl) });
}
