// @ts-check
import js from "@eslint/js";
import { defineConfig } from "eslint/config";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import globals from "globals";
import tseslint from "typescript-eslint";

export default defineConfig(
  {
    ignores: [
      "**/node_modules/**",
      "**/dist/**",
      "**/coverage/**",
      "contracts/out/**",
      "contracts/cache/**",
      "contracts/broadcast/**",
      "apps/web/test-results/**",
      "apps/web/playwright-report/**",
      "ml/**",
    ],
  },
  js.configs.recommended,
  tseslint.configs.strict,
  {
    rules: {
      // Model and tool output is untrusted; never evaluate strings as code (handbook 8.4).
      "no-eval": "error",
      "no-implied-eval": "error",
      "no-new-func": "error",
      "@typescript-eslint/consistent-type-imports": "error",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },
  {
    files: ["scripts/**/*.ts", "redteam/**/*.ts", "eval/**/*.ts", "**/*.config.{js,ts}"],
    languageOptions: { globals: globals.node },
  },
  {
    files: ["apps/web/src/**/*.{ts,tsx}"],
    languageOptions: { globals: globals.browser },
    plugins: { "react-hooks": reactHooks, "react-refresh": reactRefresh },
    rules: {
      ...reactHooks.configs.flat.recommended.rules,
      ...reactRefresh.configs.vite.rules,
      // XSS is the main way a browser-held session key leaks (handbook 3.4, 8.4).
      "no-restricted-syntax": [
        "error",
        {
          selector: "JSXAttribute[name.name='dangerouslySetInnerHTML']",
          message:
            "dangerouslySetInnerHTML is forbidden: render model and document text as plain text.",
        },
      ],
    },
  },
);
