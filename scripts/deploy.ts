/**
 * Deploys the contracts with script/Deploy.s.sol.
 *
 *   pnpm deploy:local    Needs anvil running (`pnpm dev` starts one). Uses anvil's unlocked account.
 *   pnpm deploy:testnet  Base Sepolia. Reads DEPLOYER_PRIVATE_KEY, VITE_RPC_URL and
 *                        BASESCAN_API_KEY from the root .env, deploys and verifies the source
 *                        (on Basescan with a key, on Blockscout without one), seeds the demo
 *                        vault (script/SeedDemo.s.sol), then writes the addresses back into .env.
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
import { testnetTarget } from "./lib/testnet.ts";

const BLOCKSCOUT_API = "https://base-sepolia.blockscout.com/api/";

async function deployLocal(): Promise<void> {
  const chainId = await rpcChainId(ANVIL_RPC_URL);
  if (chainId !== ANVIL_CHAIN_ID) {
    throw new Error(`No anvil node at ${ANVIL_RPC_URL}. Start one with \`anvil\` or \`pnpm dev\`.`);
  }
  // --rpc-url is passed explicitly: `forge script` ignores ETH_RPC_URL and would otherwise
  // simulate on an in-memory chain.
  await run(
    "forge",
    [
      "script",
      "script/Deploy.s.sol",
      "--rpc-url",
      ANVIL_RPC_URL,
      "--broadcast",
      "--unlocked",
      "--sender",
      ANVIL_SENDER,
    ],
    { cwd: contractsDir, env: toolEnv({ DEPLOYER_PRIVATE_KEY: undefined }) },
  );
  console.log(readDeployment(ANVIL_CHAIN_ID));
}

async function deployTestnet(): Promise<void> {
  const env = readEnvFile(rootEnvPath);
  const key = env["DEPLOYER_PRIVATE_KEY"]?.trim();
  if (!key) throw new Error("DEPLOYER_PRIVATE_KEY is empty in .env. Run `pnpm new-deployer-key`.");
  const { rpcUrl, rehearsal } = testnetTarget(env);

  // Testnet only (handbook rule 3): refuse to broadcast anywhere but Base Sepolia (or a fork of it).
  const chainId = await rpcChainId(rpcUrl, 10_000);
  if (chainId !== BASE_SEPOLIA_CHAIN_ID) {
    throw new Error(
      `The RPC serves chain ${chainId ?? "(no answer)"}, expected Base Sepolia (${BASE_SEPOLIA_CHAIN_ID}).`,
    );
  }

  const apiKey = env["BASESCAN_API_KEY"]?.trim();
  // With an Etherscan V2 key, verify on Basescan. Without one, verify on Base Sepolia's
  // Blockscout explorer, which needs no key; `pnpm verify:testnet` adds Basescan later.
  // A rehearsal on a local fork verifies nothing (the contracts exist only in the fork).
  let verify: string[] = [];
  if (rehearsal) {
    console.log("Rehearsal on a local fork: skipping source verification.");
  } else if (apiKey) {
    verify = ["--verify"];
  } else {
    verify = ["--verify", "--verifier", "blockscout", "--verifier-url", BLOCKSCOUT_API];
    console.warn(
      "BASESCAN_API_KEY is empty: verifying on Blockscout (base-sepolia.blockscout.com) instead. " +
        "Add the key later and run `pnpm verify:testnet` to verify on Basescan too.",
    );
  }
  const forgeEnv = toolEnv({
    DEPLOYER_PRIVATE_KEY: key,
    ETHERSCAN_API_KEY: apiKey,
    BASESCAN_API_KEY: undefined,
    // SeedDemo overrides (SEED_FUND, SEED_BUFFER, ...) may be set in .env.
    ...Object.fromEntries(Object.entries(env).filter(([name]) => name.startsWith("SEED_"))),
  });
  // --rpc-url is passed explicitly: `forge script` ignores ETH_RPC_URL.
  const common = ["--rpc-url", rpcUrl, "--broadcast", ...verify];

  await run("forge", ["script", "script/Deploy.s.sol", ...common], {
    cwd: contractsDir,
    env: forgeEnv,
  });
  // The demo vault for the deployer (the demo owner): used by `pnpm raw-attack testnet` and the
  // evidence script. Idempotent, so re-running is safe.
  await run("forge", ["script", "script/SeedDemo.s.sol", ...common], {
    cwd: contractsDir,
    env: forgeEnv,
  });

  if (rehearsal) return;
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
