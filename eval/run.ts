/**
 * Task-completion runner (handbook 9.2). Tasks live in eval/tasks/*.json; success is checked
 * on-chain and in app state, never in the model's text.
 *
 * Phase 1: only loads and counts tasks, and fails if any exist, because a task that cannot be
 * run must never count as a pass. Phase 9 replaces this with the real runner.
 */
import { join } from "node:path";
import { loadJsonCases } from "../scripts/lib/cases.ts";
import { repoRoot } from "../scripts/lib/tools.ts";

const tasks = loadJsonCases(join(repoRoot, "eval", "tasks"));
if (tasks.length === 0) {
  console.log("Task-completion suite: 0 tasks (the suite is built in Phase 9). Nothing to run.");
} else {
  console.error(
    `Task-completion suite: found ${tasks.length} task(s), but the runner is not implemented yet (Phase 9).`,
  );
  process.exit(1);
}
