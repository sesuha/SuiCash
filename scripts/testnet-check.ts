/**
 * Checks everything `pnpm deploy:testnet` and `pnpm raw-attack testnet` need, and says exactly what
 * to fix. Read-only: it sends no transactions and never prints the private key.
 *
 *   pnpm testnet:check
 */
import { createPublicClient, formatEther, formatUnits, http, parseEther, type Address } from "viem";
import { privateKeyToAddress } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { readEnvFile, rootEnvPath } from "./lib/env.ts";
import { BASE_SEPOLIA_CHAIN_ID } from "./lib/tools.ts";

const USDC: Address = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
/** Deploy + seed + raw attack cost well under this on Base Sepolia; the margin covers L1 fees. */
const MIN_ETH = parseEther("0.003");

const erc20 = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "a", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

let blocking = 0;
const ok = (msg: string) => console.log(`  \x1b[32m✓\x1b[0m ${msg}`);
const warn = (msg: string) => console.log(`  \x1b[33m!\x1b[0m ${msg}`);
const fail = (msg: string, fix: string) => {
  blocking++;
  console.log(`  \x1b[31m✗\x1b[0m ${msg}\n      → ${fix}`);
};

async function etherscanKeyWorks(key: string, addr: Address): Promise<boolean | null> {
  const url =
    `https://api.etherscan.io/v2/api?chainid=${BASE_SEPOLIA_CHAIN_ID}&module=account&action=balance` +
    `&address=${addr}&tag=latest&apikey=${encodeURIComponent(key)}`;
  try {
    const body = (await (await fetch(url, { signal: AbortSignal.timeout(10_000) })).json()) as {
      status?: string;
    };
    return body.status === "1";
  } catch {
    return null; // network problem: unknown
  }
}

async function main(): Promise<void> {
  const env = readEnvFile(rootEnvPath);
  console.log("SuiCash testnet readiness (Base Sepolia)\n");

  const key = env["DEPLOYER_PRIVATE_KEY"]?.trim();
  if (!key || !/^0x[0-9a-fA-F]{64}$/.test(key)) {
    fail("No valid DEPLOYER_PRIVATE_KEY in .env", "Run `pnpm new-deployer-key`.");
    return summary();
  }
  const deployer = privateKeyToAddress(key as `0x${string}`);
  ok(`Deployer address: ${deployer}`);

  const rpcUrl = env["VITE_RPC_URL"]?.trim() || "https://sepolia.base.org";
  const client = createPublicClient({ chain: baseSepolia, transport: http(rpcUrl) });
  let chainId: number;
  try {
    chainId = await client.getChainId();
  } catch {
    fail(`RPC ${new URL(rpcUrl).host} did not answer`, "Check VITE_RPC_URL in .env.");
    return summary();
  }
  if (chainId !== BASE_SEPOLIA_CHAIN_ID) {
    fail(`RPC serves chain ${chainId}, not Base Sepolia (84532)`, "Fix VITE_RPC_URL in .env.");
    return summary();
  }
  ok(`RPC ${new URL(rpcUrl).host} serves Base Sepolia`);

  const eth = await client.getBalance({ address: deployer });
  if (eth >= MIN_ETH) {
    ok(`ETH balance ${formatEther(eth)} (need at least ${formatEther(MIN_ETH)})`);
  } else {
    fail(
      `ETH balance ${formatEther(eth)}; need at least ${formatEther(MIN_ETH)} for gas`,
      `Send Base Sepolia ETH to ${deployer} (README, "Testnet setup").`,
    );
  }

  const usdc = await client.readContract({
    address: USDC,
    abi: erc20,
    functionName: "balanceOf",
    args: [deployer],
  });
  const fund = BigInt(env["SEED_FUND"]?.trim() || "2000000000");
  const buffer = BigInt(env["SEED_BUFFER"]?.trim() || "50000000");
  if (usdc === 0n) {
    warn(
      `USDC balance 0: the demo vault will be created empty. Optional for Phase 2; get 20 at https://faucet.circle.com (Base Sepolia, ${deployer}).`,
    );
  } else {
    const funded = usdc < fund ? usdc : fund;
    ok(
      `USDC balance ${formatUnits(usdc, 6)}; the demo vault will receive ${formatUnits(funded, 6)}`,
    );
    if (funded <= buffer) {
      warn(
        `SEED_BUFFER (${formatUnits(buffer, 6)} USDC) is not below the vault's funding (${formatUnits(funded, 6)}): every agent payment would hit BelowSafetyBuffer. Set SEED_BUFFER lower in .env.`,
      );
    }
  }

  const apiKey = env["BASESCAN_API_KEY"]?.trim();
  if (!apiKey) {
    warn(
      "BASESCAN_API_KEY empty: contracts will be verified on Blockscout only. Add a key, then run `pnpm verify:testnet`.",
    );
  } else {
    const works = await etherscanKeyWorks(apiKey, deployer);
    if (works === true) ok("BASESCAN_API_KEY accepted by the Etherscan V2 API");
    else if (works === false)
      fail(
        "BASESCAN_API_KEY was rejected by Etherscan",
        "Copy the key again from https://etherscan.io/myapikey.",
      );
    else warn("Could not reach api.etherscan.io to test BASESCAN_API_KEY.");
  }

  summary();
}

function summary(): void {
  console.log(
    blocking === 0
      ? "\nReady. Next: `pnpm deploy:testnet`, then `pnpm raw-attack testnet`."
      : `\n${blocking} blocking item(s) above. Fix them, then run \`pnpm testnet:check\` again.`,
  );
  process.exitCode = blocking === 0 ? 0 : 1;
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
