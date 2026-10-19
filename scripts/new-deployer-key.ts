/**
 * Creates a TESTNET deployer key and stores it in the root .env (gitignored).
 * Prints only the address to fund; the key itself is never printed or logged.
 * If .env already has a key, prints its address and changes nothing.
 */
import { copyFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { generatePrivateKey, privateKeyToAddress } from "viem/accounts";
import { readEnvFile, rootEnvPath, upsertEnvFile } from "./lib/env.ts";
import { repoRoot } from "./lib/tools.ts";

if (!existsSync(rootEnvPath)) {
  copyFileSync(join(repoRoot, ".env.example"), rootEnvPath);
  console.log("Created .env from .env.example.");
}

const existing = readEnvFile(rootEnvPath)["DEPLOYER_PRIVATE_KEY"]?.trim();
if (existing) {
  console.log(
    `.env already has a deployer key. Address: ${privateKeyToAddress(existing as `0x${string}`)}`,
  );
} else {
  const key = generatePrivateKey();
  upsertEnvFile(rootEnvPath, { DEPLOYER_PRIVATE_KEY: key });
  console.log(`New testnet deployer key saved to .env. Address: ${privateKeyToAddress(key)}`);
  console.log("TESTNET ONLY. Never send mainnet funds to this address.");
}
console.log(
  "Fund it with Base Sepolia ETH (Coinbase Developer Platform faucet) and test USDC (https://faucet.circle.com).",
);
