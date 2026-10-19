import { describe, expect, it } from "vitest";
import {
  ANVIL_CHAIN_ID,
  BASE_SEPOLIA_CHAIN_ID,
  BASE_SEPOLIA_USDC,
  parseChainConfig,
  resolveChain,
} from "../src/index.ts";

describe("resolveChain", () => {
  it("accepts Base Sepolia and anvil", () => {
    expect(resolveChain(BASE_SEPOLIA_CHAIN_ID).id).toBe(84532);
    expect(resolveChain(ANVIL_CHAIN_ID).id).toBe(31337);
  });

  it("refuses mainnets (testnet only)", () => {
    expect(() => resolveChain(1)).toThrow(/Unsupported chain ID 1/);
    expect(() => resolveChain(8453)).toThrow(/Unsupported chain ID 8453/);
  });
});

describe("parseChainConfig", () => {
  it("parses a full testnet config and checksums addresses", () => {
    const config = parseChainConfig({
      VITE_CHAIN_ID: "84532",
      VITE_RPC_URL: "https://sepolia.base.org",
      VITE_USDC_ADDRESS: BASE_SEPOLIA_USDC.toLowerCase(),
      VITE_BUNDLER_URL: "",
    });
    expect(config.chain.id).toBe(84532);
    expect(config.rpcUrl).toBe("https://sepolia.base.org");
    expect(config.usdc).toBe(BASE_SEPOLIA_USDC);
    expect(config.bundlerUrl).toBeNull();
    expect(config.vaultFactory).toBeNull();
  });

  it("falls back to the chain's default RPC URL", () => {
    const config = parseChainConfig({ VITE_CHAIN_ID: "31337" });
    expect(config.rpcUrl).toBe("http://127.0.0.1:8545");
  });

  it("rejects a missing or non-numeric chain ID", () => {
    expect(() => parseChainConfig({})).toThrow(/VITE_CHAIN_ID/);
    expect(() => parseChainConfig({ VITE_CHAIN_ID: "base" })).toThrow(/VITE_CHAIN_ID/);
  });

  it("rejects invalid addresses and URLs", () => {
    expect(() => parseChainConfig({ VITE_CHAIN_ID: "84532", VITE_USDC_ADDRESS: "0x1234" })).toThrow(
      /VITE_USDC_ADDRESS/,
    );
    expect(() =>
      parseChainConfig({ VITE_CHAIN_ID: "84532", VITE_RPC_URL: "javascript:alert(1)" }),
    ).toThrow(/VITE_RPC_URL/);
  });
});
