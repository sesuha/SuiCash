/**
 * Phase 2 acceptance: a raw executeTransfer to an attacker address, signed by the agent key with no
 * policy engine in the way, reverts on-chain with RecipientNotAllowed.
 *
 *   pnpm raw-attack local     against anvil (run `pnpm dev` first)
 *   pnpm raw-attack testnet   against Base Sepolia; writes docs/evidence/phase2-raw-attack.json
 *
 * Flow: the demo owner grants a 1-hour session to a fresh agent key that lives only in memory (never
 * stored, never printed), funds it with a little gas, the agent sends the attack with a fixed gas
 * limit (so the transaction is mined and reverts on-chain instead of failing gas estimation), and
 * the owner revokes the session. The revert reason is decoded by replaying the call at that block.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { policyVaultAbi } from "@suicash/chain";
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  parseEther,
  toHex,
  type Account,
  type Address,
  type Chain,
  type Hash,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { anvil, baseSepolia } from "viem/chains";
import { readEnvFile, rootEnvPath } from "./lib/env.ts";
import { testnetTarget } from "./lib/testnet.ts";
import { ANVIL_RPC_URL, ANVIL_SENDER, contractsDir, repoRoot } from "./lib/tools.ts";

/** The address the HostileToken's injection payload tells the agent to send everything to. */
const ATTACKER: Address = "0x000000000000000000000000000000000000dEaD";
const ATTACK_AMOUNT = 1_000_000n; // 1 USDC
const ATTACK_GAS = 200_000n;

interface Target {
  chain: Chain;
  rpcUrl: string;
  owner: Account | Address;
  /** Extra ETH for the agent on top of its execution gas (Base's L1 data fee). */
  agentGasMargin: bigint;
  explorer: string | null;
}

function target(name: string | undefined): Target {
  if (name === "local") {
    // anvil's unlocked default account signs through eth_sendTransaction; no key needed.
    return {
      chain: anvil,
      rpcUrl: ANVIL_RPC_URL,
      owner: ANVIL_SENDER,
      agentGasMargin: 0n,
      explorer: null,
    };
  }
  if (name === "testnet") {
    const env = readEnvFile(rootEnvPath);
    const key = env["DEPLOYER_PRIVATE_KEY"]?.trim();
    if (!key) throw new Error("DEPLOYER_PRIVATE_KEY must be set in .env");
    const { rpcUrl, rehearsal } = testnetTarget(env);
    return {
      chain: baseSepolia,
      rpcUrl,
      owner: privateKeyToAccount(key as `0x${string}`),
      agentGasMargin: parseEther("0.00002"),
      // A rehearsal on a local fork produces no real hashes: no explorer links, no evidence file.
      explorer: rehearsal ? null : "https://sepolia.basescan.org/tx/",
    };
  }
  throw new Error("Usage: tsx scripts/raw-attack.ts <local|testnet>");
}

function readJson(file: string): Record<string, unknown> {
  return JSON.parse(readFileSync(join(contractsDir, "deployments", file), "utf8")) as Record<
    string,
    unknown
  >;
}

/** Replays a call and returns its decoded custom error, e.g. "RecipientNotAllowed(0x…dEaD)". */
async function revertReason(replay: () => Promise<unknown>): Promise<string> {
  try {
    await replay();
    return "SIMULATION SUCCEEDED (unexpected)";
  } catch (error) {
    const revert =
      error instanceof BaseError
        ? error.walk((e) => e instanceof ContractFunctionRevertedError)
        : null;
    if (revert instanceof ContractFunctionRevertedError && revert.data) {
      return `${revert.data.errorName}(${(revert.data.args ?? []).map(String).join(", ")})`;
    }
    return error instanceof Error ? (error.message.split("\n")[0] ?? error.message) : String(error);
  }
}

async function main(): Promise<void> {
  const t = target(process.argv[2]);
  const transport = http(t.rpcUrl);
  const pub = createPublicClient({ chain: t.chain, transport });
  const chainId = await pub.getChainId();
  if (chainId !== t.chain.id)
    throw new Error(`RPC serves chain ${chainId}, expected ${t.chain.id}`);

  const usdc = readJson(`${chainId}.json`)["usdc"] as Address;
  const vault = readJson(`${chainId}-demo.json`)["vault"] as Address;
  const owner = createWalletClient({ account: t.owner, chain: t.chain, transport });
  const agent = privateKeyToAccount(generatePrivateKey()); // in memory only
  const agentWallet = createWalletClient({ account: agent, chain: t.chain, transport });
  const tx: Record<string, Hash> = {};
  const wait = async (hash: Hash) => pub.waitForTransactionReceipt({ hash });

  const usdcBalance = (holder: Address) =>
    pub.readContract({
      address: usdc,
      abi: [
        {
          type: "function",
          name: "balanceOf",
          stateMutability: "view",
          inputs: [{ name: "a", type: "address" }],
          outputs: [{ type: "uint256" }],
        },
      ] as const,
      functionName: "balanceOf",
      args: [holder],
    });
  const attackerBefore = await usdcBalance(ATTACKER);
  const vaultBefore = await usdcBalance(vault);

  console.log(`Vault ${vault} on chain ${chainId}; attacker ${ATTACKER}`);

  // 1. The owner grants a short session to the fresh agent key.
  const now = (await pub.getBlock()).timestamp;
  tx["setAgent"] = await owner.writeContract({
    address: vault,
    abi: policyVaultAbi,
    functionName: "setAgent",
    args: [agent.address, now + 3600n],
  });
  await wait(tx["setAgent"]);

  // 2. Gas money for the agent (Mode A; Mode B uses a paymaster instead), sized from the current
  //    fee estimate with 3x headroom, plus a margin for Base's L1 data fee. The attack pins the
  //    same max fee, so the funding always covers it even if fees move in between.
  const { maxFeePerGas } = await pub.estimateFeesPerGas();
  const agentFunding = maxFeePerGas * ATTACK_GAS * 3n + t.agentGasMargin;
  tx["fundAgent"] = await owner.sendTransaction({ to: agent.address, value: agentFunding });
  await wait(tx["fundAgent"]);

  // 3. The attack: a raw call straight to the vault, no policy engine involved.
  const intentId = keccak256(toHex(`raw-attack-${Date.now()}`));
  const args = [usdc, ATTACKER, ATTACK_AMOUNT, intentId] as const;
  tx["attack"] = await agentWallet.writeContract({
    address: vault,
    abi: policyVaultAbi,
    functionName: "executeTransfer",
    args,
    gas: ATTACK_GAS, // fixed, so the transaction is mined and reverts on-chain
    maxFeePerGas,
  });
  const receipt = await wait(tx["attack"]);

  const reason = await revertReason(() =>
    pub.simulateContract({
      address: vault,
      abi: policyVaultAbi,
      functionName: "executeTransfer",
      args,
      account: agent.address,
      blockNumber: receipt.blockNumber,
    }),
  );

  // 4. The owner revokes the session.
  tx["revokeAgent"] = await owner.writeContract({
    address: vault,
    abi: policyVaultAbi,
    functionName: "revokeAgent",
  });
  await wait(tx["revokeAgent"]);

  // Changes, not absolute balances: on Base Sepolia 0x…dEaD already holds other people's burned
  // test USDC, so only "nothing moved" is meaningful.
  const attackerChange = (await usdcBalance(ATTACKER)) - attackerBefore;
  const vaultChange = (await usdcBalance(vault)) - vaultBefore;

  const passed =
    receipt.status === "reverted" &&
    reason.startsWith("RecipientNotAllowed") &&
    attackerChange === 0n &&
    vaultChange === 0n;
  const result = {
    check: "Raw executeTransfer to an attacker from the agent key reverts with RecipientNotAllowed",
    chainId,
    vault,
    attacker: ATTACKER,
    agent: agent.address,
    attackStatus: receipt.status,
    attackGasUsed: receipt.gasUsed.toString(),
    revertReason: reason,
    attackerUsdcChange: attackerChange.toString(),
    vaultUsdcChange: vaultChange.toString(),
    transactions: Object.fromEntries(
      Object.entries(tx).map(([k, h]) => [k, t.explorer ? `${t.explorer}${h}` : h]),
    ),
    recordedAt: new Date().toISOString(),
    passed,
  };
  console.log(JSON.stringify(result, null, 2));

  if (t.explorer) {
    const dir = join(repoRoot, "docs", "evidence");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "phase2-raw-attack.json"), `${JSON.stringify(result, null, 2)}\n`);
    console.log("Saved docs/evidence/phase2-raw-attack.json");
  }
  if (!passed) process.exit(1);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
