import { describe, expect, it } from "vitest";
import { TIERS, TIER_DESCRIPTIONS, USDC_DECIMALS, stricterTier } from "../src/index.ts";

describe("core vocabulary", () => {
  it("uses 6 decimals for USDC", () => {
    expect(USDC_DECIMALS).toBe(6);
  });

  it("orders tiers from least to most restrictive", () => {
    expect(TIERS).toEqual(["T0", "T1", "T2", "T3"]);
  });

  it("describes every tier", () => {
    for (const tier of TIERS) {
      expect(TIER_DESCRIPTIONS[tier]).toBeTruthy();
    }
  });

  it("stricterTier always picks the more restrictive tier", () => {
    expect(stricterTier("T1", "T3")).toBe("T3");
    expect(stricterTier("T3", "T1")).toBe("T3");
    expect(stricterTier("T2", "T1")).toBe("T2");
    expect(stricterTier("T0", "T0")).toBe("T0");
  });
});
