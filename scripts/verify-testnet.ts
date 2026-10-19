/**
 * Verifies the deployed Base Sepolia contracts on Basescan, for when `pnpm deploy:testnet` ran
 * before BASESCAN_API_KEY was set (it then verifies on Blockscout only). Safe to re-run: forge
 * skips contracts that are already verified.
 *
 *   pnpm verify:testnet
 *
 * Reads contracts/deployments/84532.json and 84532-demo.json, and BASESCAN_API_KEY (an Etherscan
 * V2 key) from .env. The key goes to forge as ETHERSCAN_API_KEY, never on the command line.
 */
import { existsSync, readFileSync } from "node:fs";
import { encodeAbiParameters, type Address, type Hex } from "viem";
import { deploymentPath, readEnvFile, rootEnvPath } from "./lib/env.ts";
import { BASE_SEPOLIA_CHAIN_ID, contractsDir, requireTool, run, toolEnv } from "./lib/tools.ts";

interface Target {
  label: string;
  address: Address;
  contract: string; // path:Name as forge expects
  constructorArgs: Hex;
}

function readJson(path: string): Record<string, string> {
  if (!existsSync(path)) throw new Error(`Missing ${path}. Run \`pnpm deploy:testnet\` first.`);
  return JSON.parse(readFileSync(path, "utf8")) as Record<string, string>;
}

const address = (value: string | undefined, name: string): Address => {
  if (!value || !/^0x[0-9a-fA-F]{40}$/.test(value))
    throw new Error(`Bad or missing ${name} in deployments`);
  return value as Address;
};

async function main(): Promise<void> {
  requireTool("forge", "Install Foundry: https://book.getfoundry.sh/getting-started/installation");
  const env = readEnvFile(rootEnvPath);
  const apiKey = env["BASESCAN_API_KEY"]?.trim();
  const rpcUrl = env["VITE_RPC_URL"]?.trim();
  if (!apiKey) throw new Error("BASESCAN_API_KEY is empty in .env. See README, Testnet setup.");
  if (!rpcUrl) throw new Error("VITE_RPC_URL is empty in .env.");

  const d = readJson(deploymentPath(BASE_SEPOLIA_CHAIN_ID));
  const demoPath = deploymentPath(BASE_SEPOLIA_CHAIN_ID).replace(/\.json$/, "-demo.json");
  const demo = existsSync(demoPath) ? readJson(demoPath) : null;

  const usdc = address(d["usdc"], "usdc");
  const deployer = address(d["deployer"], "deployer");
  const pool = address(d["savingsPool"], "savingsPool");
  const two = [{ type: "address" }, { type: "address" }] as const;

  const targets: Target[] = [
    {
      label: "SavingsPool",
      address: pool,
      contract: "src/SavingsPool.sol:SavingsPool",
      constructorArgs: encodeAbiParameters(two, [usdc, deployer]),
    },
    {
      label: "VaultFactory",
      address: address(d["vaultFactory"], "vaultFactory"),
      contract: "src/VaultFactory.sol:VaultFactory",
      constructorArgs: encodeAbiParameters([{ type: "address" }], [pool]),
    },
  ];
  if (demo) {
    const owner = address(demo["owner"], "demo owner");
    targets.push(
      {
        label: "PolicyVault (demo)",
        address: address(demo["vault"], "demo vault"),
        contract: "src/PolicyVault.sol:PolicyVault",
        constructorArgs: encodeAbiParameters(two, [owner, pool]),
      },
      {
        label: "HostileToken (demo)",
        address: address(demo["hostileToken"], "hostileToken"),
        contract: "src/test/HostileToken.sol:HostileToken",
        constructorArgs: "0x",
      },
    );
  }

  // The key goes through the environment; --rpc-url explicitly, since forge ignores ETH_RPC_URL.
  const forgeEnv = toolEnv({ ETHERSCAN_API_KEY: apiKey, BASESCAN_API_KEY: undefined });
  for (const t of targets) {
    console.log(`\nVerifying ${t.label} at ${t.address} on Basescan…`);
    const args = [
      "verify-contract",
      t.address,
      t.contract,
      "--chain",
      String(BASE_SEPOLIA_CHAIN_ID),
      "--rpc-url",
      rpcUrl,
      "--watch",
    ];
    if (t.constructorArgs !== "0x") args.push("--constructor-args", t.constructorArgs);
    await run("forge", args, { cwd: contractsDir, env: forgeEnv });
  }
  console.log("\nDone. Each contract's Basescan page now has a 'Contract' tab with the source.");
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
