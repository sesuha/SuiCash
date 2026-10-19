import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export interface CaseFile {
  file: string;
  data: unknown;
}

/** Loads every *.json file in a directory, sorted by name. A missing directory gives []. */
export function loadJsonCases(dir: string): CaseFile[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => {
      const file = join(dir, name);
      try {
        return { file, data: JSON.parse(readFileSync(file, "utf8")) as unknown };
      } catch (error) {
        throw new Error(
          `Invalid JSON in ${file}: ${error instanceof Error ? error.message : String(error)}`,
          { cause: error },
        );
      }
    });
}
