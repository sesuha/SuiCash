import { expect, test } from "@playwright/test";

test("the app shell loads", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle("SuiCash");
  await expect(page.getByRole("heading", { level: 1, name: "SuiCash" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Permission tiers" })).toBeVisible();
  // Either a network panel or a clear configuration message, never a blank page.
  await expect(page.getByTestId("chain-status").or(page.getByTestId("config-error"))).toBeVisible();
});
