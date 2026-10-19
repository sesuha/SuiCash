import { parseChainConfig, type ChainConfig, type ChainEnv } from "@suicash/chain";

export type ConfigResult = { ok: true; config: ChainConfig } | { ok: false; error: string };

/** Validates the VITE_* environment once at startup; the UI shows the error instead of crashing. */
export function loadConfig(env: ChainEnv): ConfigResult {
  try {
    return { ok: true, config: parseChainConfig(env) };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

/** Shows only the RPC host, never a path or query string (provider URLs often embed API keys). */
export function rpcHost(rpcUrl: string): string {
  return new URL(rpcUrl).host;
}
