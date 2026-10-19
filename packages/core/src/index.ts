/**
 * @suicash/core: the shared, deterministic heart of SuiCash.
 *
 * Phase 1 holds only the vocabulary every later phase builds on. The intent
 * schema (Phase 4.1), policy engine (Phase 4) and fallback parser (Phase 5.8)
 * are added here in their phases.
 */

/** Test USDC uses 6 decimals. Amounts are decimal strings parsed with parseUnits, never floats. */
export const USDC_DECIMALS = 6;

/**
 * Permission tiers.
 * T0 read-only, T1 automatic, T2 needs owner approval, T3 blocked.
 */
export const TIERS = ["T0", "T1", "T2", "T3"] as const;
export type Tier = (typeof TIERS)[number];

export const TIER_DESCRIPTIONS: Readonly<Record<Tier, string>> = {
  T0: "Read-only",
  T1: "Automatic",
  T2: "Needs owner approval",
  T3: "Blocked",
};

/** Returns the stricter of two tiers. Used to combine check results: any block wins. */
export function stricterTier(a: Tier, b: Tier): Tier {
  return TIERS.indexOf(a) >= TIERS.indexOf(b) ? a : b;
}
