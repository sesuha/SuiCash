/**
 * Where the testnet scripts send transactions. Normally Base Sepolia via VITE_RPC_URL from .env.
 * `pnpm testnet:rehearse` sets TESTNET_RPC_URL to a local anvil fork of Base Sepolia; that run is a
 * rehearsal: nothing is verified, .env is not updated and no evidence file is written.
 */
export interface TestnetTarget {
  rpcUrl: string;
  rehearsal: boolean;
}

export function testnetTarget(env: Record<string, string>): TestnetTarget {
  const override = process.env["TESTNET_RPC_URL"]?.trim();
  const rpcUrl = override || env["VITE_RPC_URL"]?.trim();
  if (!rpcUrl) throw new Error("VITE_RPC_URL is empty in .env.");
  const rehearsal = !!override && /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/.test(override);
  return { rpcUrl, rehearsal };
}
