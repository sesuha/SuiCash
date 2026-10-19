/**
 * Rehearses the Base Sepolia flow on a local fork of the real chain, before spending faucet ETH:
 * the same `pnpm deploy:testnet` and `pnpm raw-attack testnet` commands, against real chain state
 * (including Circle's USDC contract), with the deployer's balance set on the fork only.
 *
 *   pnpm testnet:rehearse
 *
 * Nothing is broadcast to Base Sepolia, nothing is verified, .env is not changed and no evidence
 * is written. Real deployment files for chain 84532, if any, are backed up and restored.
 * Reports the ETH the flow used, so you know how much to request from a faucet.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import {
  createPublicClient,
  encodeAbiParameters,
  formatEther,
  http,
  keccak256,
  numberToHex,
  pad,
  parseEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAddress } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { readEnvFile, rootEnvPath } from "./lib/env.ts";
import { contractsDir, killTree, repoRoot, rpcCall, toolEnv, waitForRpc } from "./lib/tools.ts";

const FORK_PORT = 8546;
const FORK_URL = `http://127.0.0.1:${FORK_PORT}`;
const USDC: Address = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const FORK_ETH = parseEther("0.05");
const FORK_USDC = 20_000_000n; // 20 USDC, what one faucet request gives

/** Files a run for chain 84532 writes; backed up before and restored after. */
const ARTIFACTS = [
  join(contractsDir, "deployments", "84532.json"),
  join(contractsDir, "deployments", "84532-demo.json"),
  join(contractsDir, "broadcast", "Deploy.s.sol", "84532"),
  join(contractsDir, "broadcast", "SeedDemo.s.sol", "84532"),
  join(contractsDir, "cache", "Deploy.s.sol", "84532"),
  join(contractsDir, "cache", "SeedDemo.s.sol", "84532"),
];
const backup = (path: string) => `${path}.rehearsal-backup`;

const erc20 = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "a", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

function log(message: string): void {
  console.log(`\x1b[35m[rehearse]\x1b[0m ${message}`);
}

function runShell(command: string, env: NodeJS.ProcessEnv): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, { cwd: repoRoot, env, stdio: "inherit", shell: true });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`"${command}" exited with ${code}`)),
    );
  });
}

/** Finds the storage slot of USDC's balance mapping on the fork and writes a balance there. */
async function setUsdcBalance(holder: Address, amount: bigint): Promise<boolean> {
  const client = createPublicClient({ chain: baseSepolia, transport: http(FORK_URL) });
  for (let slot = 0n; slot < 20n; slot++) {
    const key = keccak256(
      encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [holder, slot]),
    );
    const previous = (await rpcCall(FORK_URL, "eth_getStorageAt", [USDC, key, "latest"])) as Hex;
    await rpcCall(FORK_URL, "anvil_setStorageAt", [USDC, key, pad(numberToHex(amount))]);
    const balance = await client.readContract({
      address: USDC,
      abi: erc20,
      functionName: "balanceOf",
      args: [holder],
    });
    if (balance === amount) return true;
    await rpcCall(FORK_URL, "anvil_setStorageAt", [USDC, key, previous]);
  }
  return false;
}

async function main(): Promise<void> {
  const env = readEnvFile(rootEnvPath);
  const key = env["DEPLOYER_PRIVATE_KEY"]?.trim();
  const upstream = env["VITE_RPC_URL"]?.trim();
  if (!key || !upstream)
    throw new Error("DEPLOYER_PRIVATE_KEY and VITE_RPC_URL must be set in .env");
  const deployer = privateKeyToAddress(key as `0x${string}`);

  for (const path of ARTIFACTS) {
    if (existsSync(backup(path)))
      throw new Error(`Leftover backup ${backup(path)}: restore or delete it first.`);
  }
  for (const path of ARTIFACTS) if (existsSync(path)) renameSync(path, backup(path));

  let anvil: ChildProcess | null = null;
  try {
    log(`Forking Base Sepolia from ${new URL(upstream).host} on port ${FORK_PORT}…`);
    anvil = spawn("anvil", ["--fork-url", upstream, "--port", String(FORK_PORT), "--silent"], {
      env: toolEnv(),
      stdio: "inherit",
    });
    const chainId = await waitForRpc(FORK_URL, 60_000);
    if (chainId !== 84532) throw new Error(`Fork serves chain ${chainId}, expected 84532`);

    await rpcCall(FORK_URL, "anvil_setBalance", [deployer, numberToHex(FORK_ETH)]);
    const usdcSet = await setUsdcBalance(deployer, FORK_USDC);
    log(
      `On the fork only: deployer ${deployer} has ${formatEther(FORK_ETH)} ETH` +
        (usdcSet ? " and 20 USDC." : " (could not set a USDC balance; the vault will be empty)."),
    );

    const client = createPublicClient({ chain: baseSepolia, transport: http(FORK_URL) });
    const before = await client.getBalance({ address: deployer });
    const childEnv = toolEnv({ TESTNET_RPC_URL: FORK_URL });

    log("Running `pnpm deploy:testnet` against the fork…");
    await runShell("pnpm deploy:testnet", childEnv);
    log("Running `pnpm raw-attack testnet` against the fork…");
    await runShell("pnpm raw-attack testnet", childEnv);

    const used = before - (await client.getBalance({ address: deployer }));
    log(`Rehearsal passed. ETH used by deploy + seed + raw attack: ${formatEther(used)} ETH.`);
    log(
      "Base also charges a small L1 data fee that a local fork does not; " +
        "`pnpm testnet:check` asks for 0.003 ETH, which leaves a wide margin.",
    );
  } finally {
    if (anvil) killTree(anvil);
    for (const path of ARTIFACTS) {
      rmSync(path, { recursive: true, force: true });
      if (existsSync(backup(path))) renameSync(backup(path), path);
    }
    log("Cleaned up: fork stopped, rehearsal files removed, any real 84532 files restored.");
  }
}

main().catch((error: unknown) => {
  console.error(
    `\x1b[31m[rehearse]\x1b[0m ${error instanceof Error ? error.message : String(error)}`,
  );
  process.exit(1);
});
