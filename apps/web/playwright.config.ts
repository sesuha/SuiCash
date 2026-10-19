import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env["CI"],
  retries: process.env["CI"] ? 1 : 0,
  reporter: process.env["CI"] ? "github" : "list",
  use: {
    baseURL: "http://localhost:4173",
    trace: "on-first-retry",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  // `pnpm test:e2e` builds first, then serves the production build.
  webServer: {
    command: "pnpm exec vite preview",
    url: "http://localhost:4173",
    reuseExistingServer: !process.env["CI"],
  },
});
