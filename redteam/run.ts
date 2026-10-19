/**
 * Red-team runner (handbook 8.3). Modes: policy-only (CI, Node), full (browser, real model)
 * and chain (testnet raw calls). Cases live in redteam/cases/*.json.
 *
 * Phase 1: the policy engine does not exist yet, so the runner only loads and counts cases.
 * It fails if any case exists, because a case that cannot be run must never count as a pass.
 * Phase 8 replaces this with the real runner.
 */
import { join } from "node:path";
import { loadJsonCases } from "../scripts/lib/cases.ts";
import { repoRoot } from "../scripts/lib/tools.ts";

const cases = loadJsonCases(join(repoRoot, "redteam", "cases"));
if (cases.length === 0) {
  console.log("Red-team suite: 0 cases (the attack library is built in Phase 8). Nothing to run.");
} else {
  console.error(
    `Red-team suite: found ${cases.length} case(s), but the runner is not implemented yet (Phase 8).`,
  );
  process.exit(1);
}
