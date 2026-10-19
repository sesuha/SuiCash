import { spawn, spawnSync, type ChildProcess, type SpawnOptions } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
export const contractsDir = join(repoRoot, "contracts");
export const isWindows = process.platform === "win32";

export const ANVIL_RPC_URL = "http://127.0.0.1:8545";
export const ANVIL_CHAIN_ID = 31337;
export const BASE_SEPOLIA_CHAIN_ID = 84532;
/** Anvil's first default account. Public address only; `--unlocked` lets anvil sign for it. */
export const ANVIL_SENDER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

/**
 * Child-process environment with Foundry's default install dir on PATH (foundryup puts it there).
 * Keys in `extra` set to undefined are removed from the child's environment.
 */
export function toolEnv(extra: Record<string, string | undefined> = {}): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = Object.fromEntries(
    Object.entries({ ...process.env, ...extra }).filter(([, value]) => value !== undefined),
  );
  const foundryBin = join(homedir(), ".foundry", "bin");
  const pathKey = Object.keys(env).find((k) => k.toLowerCase() === "path") ?? "PATH";
  if (existsSync(foundryBin) && !(env[pathKey] ?? "").includes(foundryBin)) {
    env[pathKey] = `${env[pathKey] ?? ""}${delimiter}${foundryBin}`;
  }
  return env;
}

export function requireTool(name: string, hint: string): void {
  const result = spawnSync(name, ["--version"], { env: toolEnv(), stdio: "ignore" });
  if (result.error || result.status !== 0) {
    throw new Error(`'${name}' was not found. ${hint}`);
  }
}

/** Runs a command to completion, streaming its output. Rejects on a non-zero exit. */
export function run(command: string, args: string[], options: SpawnOptions = {}): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit", env: toolEnv(), ...options });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} ${args[0] ?? ""} exited with ${code}`)),
    );
  });
}

/** Kills a child and its descendants (on Windows, `child.kill()` leaves grandchildren running). */
export function killTree(child: ChildProcess): void {
  if (child.pid === undefined || child.exitCode !== null) return;
  if (isWindows) {
    spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  } else {
    child.kill("SIGTERM");
  }
}

/** Returns the chain ID served at `url`, or null if nothing answers. */
export async function rpcChainId(url: string, timeoutMs = 1500): Promise<number | null> {
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const body = (await response.json()) as { result?: string };
    return body.result ? Number.parseInt(body.result, 16) : null;
  } catch {
    return null;
  }
}

export async function waitForRpc(url: string, timeoutMs: number): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const chainId = await rpcChainId(url);
    if (chainId !== null) return chainId;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`No JSON-RPC server answered at ${url} within ${timeoutMs} ms`);
}
