import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseEnv } from "node:util";
import { contractsDir, repoRoot } from "./tools.ts";

export const rootEnvPath = join(repoRoot, ".env");
export const devEnvPath = join(repoRoot, ".env.development.local");

/** Reads a dotenv file without touching process.env. Missing file gives {}. */
export function readEnvFile(path: string): Record<string, string> {
  if (!existsSync(path)) return {};
  return parseEnv(readFileSync(path, "utf8")) as Record<string, string>;
}

/**
 * Sets the given keys in a dotenv file, keeping every other line (and comment) as is.
 * Keys not yet present are appended.
 */
export function upsertEnvFile(path: string, values: Record<string, string>): void {
  const lines = existsSync(path) ? readFileSync(path, "utf8").split(/\r?\n/) : [];
  const pending = new Map(Object.entries(values));
  const updated = lines.map((line) => {
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/.exec(line);
    const key = match?.[1];
    const value = key === undefined ? undefined : pending.get(key);
    if (key !== undefined && value !== undefined) {
      pending.delete(key);
      return `${key}=${value}`;
    }
    return line;
  });
  while (updated.length > 0 && updated[updated.length - 1] === "") updated.pop();
  for (const [key, value] of pending) updated.push(`${key}=${value}`);
  writeFileSync(path, `${updated.join("\n")}\n`);
}

/** Contract addresses as written by script/Deploy.s.sol (Phase 2 adds them). */
interface DeploymentFile {
  chainId: number;
  usdc?: string;
  savingsPool?: string;
  vaultFactory?: string;
}

export function deploymentPath(chainId: number): string {
  return join(contractsDir, "deployments", `${chainId}.json`);
}

export function readDeployment(chainId: number): DeploymentFile {
  const path = deploymentPath(chainId);
  if (!existsSync(path)) throw new Error(`No deployment file at ${path}`);
  return JSON.parse(readFileSync(path, "utf8")) as DeploymentFile;
}

/** Maps a deployment file to the web app's VITE_ address variables (empty when not deployed yet). */
export function deploymentToViteEnv(deployment: DeploymentFile): Record<string, string> {
  return {
    VITE_USDC_ADDRESS: deployment.usdc ?? "",
    VITE_VAULT_FACTORY_ADDRESS: deployment.vaultFactory ?? "",
    VITE_SAVINGS_POOL_ADDRESS: deployment.savingsPool ?? "",
  };
}
