import { describe, expect, it } from "vitest";
import { loadConfig, rpcHost } from "../src/lib/config.ts";

describe("loadConfig", () => {
  it("returns the parsed config for a valid environment", () => {
    const result = loadConfig({ VITE_CHAIN_ID: "31337", VITE_RPC_URL: "http://127.0.0.1:8545" });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.config.chain.id).toBe(31337);
  });

  it("returns an error instead of throwing for an invalid environment", () => {
    const result = loadConfig({ VITE_CHAIN_ID: "1" });
    expect(result).toEqual({ ok: false, error: expect.stringMatching(/Unsupported chain ID 1/) });
  });
});

describe("rpcHost", () => {
  it("hides the path, where providers put API keys", () => {
    expect(rpcHost("https://base-sepolia.g.alchemy.com/v2/secret-key")).toBe(
      "base-sepolia.g.alchemy.com",
    );
  });
});
