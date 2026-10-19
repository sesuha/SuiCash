/**
 * Deploys the contracts with script/Deploy.s.sol.
 *
 *   pnpm deploy:local    Needs anvil running (`pnpm dev` starts one). Uses anvil's unlocked account.
 *   pnpm deploy:testnet  Base Sepolia. Reads DEPLOYER_PRIVATE_KEY, VITE_RPC_URL and
 *                        BASESCAN_API_KEY from the root .env, deploys and verifies the source on
 *                        Basescan, seeds the demo vault (script/SeedDemo.s.sol), then writes the
 *                        deployed addresses back into .env.
 *
 * Keys and API keys are passed to forge through environment variables, never on the command
 * line, so they do not show up in process listings or shell history.
 */
import {
  deploymentToViteEnv,
  readDeployment,
  readEnvFile,
  rootEnvPath,
  upsertEnvFile,
} from "./lib/env.ts";
import {
  ANVIL_CHAIN_ID,
  ANVIL_RPC_URL,
  ANVIL_SENDER,
  BASE_SEPOLIA_CHAIN_ID,
  contractsDir,
  requireTool,
  rpcChainId,
  run,
  toolEnv,
} from "./lib/tools.ts";

async function deployLocal(): Promise<void> {
  const chainId = await rpcChainId(ANVIL_RPC_URL);
  if (chainId !== ANVIL_CHAIN_ID) {
    throw new Error(`No anvil node at ${ANVIL_RPC_URL}. Start one with \`anvil\` or \`pnpm dev\`.`);
  }
  await run(
    "forge",
    ["script", "script/Deploy.s.sol", "--broadcast", "--unlocked", "--sender", ANVIL_SENDER],
    {
      cwd: contractsDir,
      env: toolEnv({ ETH_RPC_URL: ANVIL_RPC_URL, DEPLOYER_PRIVATE_KEY: undefined }),
    },
  );
  console.log(readDeployment(ANVIL_CHAIN_ID));
}

async function deployTestnet(): Promise<void> {
  const env = readEnvFile(rootEnvPath);
  const key = env["DEPLOYER_PRIVATE_KEY"]?.trim();
  const rpcUrl = env["VITE_RPC_URL"]?.trim();
  if (!key) throw new Error("DEPLOYER_PRIVATE_KEY is empty in .env. Run `pnpm new-deployer-key`.");
  if (!rpcUrl) throw new Error("VITE_RPC_URL is empty in .env.");

  // Testnet only (handbook rule 3): refuse to broadcast anywhere but Base Sepolia.
  const chainId = await rpcChainId(rpcUrl, 10_000);
  if (chainId !== BASE_SEPOLIA_CHAIN_ID) {
    throw new Error(
      `VITE_RPC_URL serves chain ${chainId ?? "(no answer)"}, expected Base Sepolia (${BASE_SEPOLIA_CHAIN_ID}).`,
    );
  }

  const apiKey = env["BASESCAN_API_KEY"]?.trim();
  if (!apiKey) console.warn("BASESCAN_API_KEY is empty: deploying without source verification.");
  const verify = apiKey ? ["--verify"] : [];
  const forgeEnv = toolEnv({
    ETH_RPC_URL: rpcUrl,
    DEPLOYER_PRIVATE_KEY: key,
    ETHERSCAN_API_KEY: apiKey,
    BASESCAN_API_KEY: apiKey,
    // SeedDemo overrides (SEED_FUND, SEED_BUFFER, ...) may be set in .env.
    ...Object.fromEntries(Object.entries(env).filter(([name]) => name.startsWith("SEED_"))),
  });

  await run("forge", ["script", "script/Deploy.s.sol", "--broadcast", ...verify], {
    cwd: contractsDir,
    env: forgeEnv,
  });
  // The demo vault for the deployer (the demo owner): used by `pnpm raw-attack testnet` and the
  // evidence script. Idempotent, so re-running is safe.
  await run("forge", ["script", "script/SeedDemo.s.sol", "--broadcast", ...verify], {
    cwd: contractsDir,
    env: forgeEnv,
  });

  const addresses = deploymentToViteEnv(readDeployment(BASE_SEPOLIA_CHAIN_ID));
  const deployed = Object.fromEntries(
    Object.entries(addresses).filter(([, value]) => value !== ""),
  );
  if (Object.keys(deployed).length > 0) {
    upsertEnvFile(rootEnvPath, deployed);
    console.log("Updated .env with:", deployed);
  }
}

async function main(): Promise<void> {
  requireTool("forge", "Install Foundry: https://book.getfoundry.sh/getting-started/installation");
  const target = process.argv[2];
  if (target === "local") return deployLocal();
  if (target === "testnet") return deployTestnet();
  throw new Error("Usage: tsx scripts/deploy.ts <local|testnet>");
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
