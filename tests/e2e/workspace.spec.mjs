// SPDX-License-Identifier: Apache-2.0 OR MIT
import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

test("million-event workspace stays windowed and supports its keyboard path", async ({ page }) => {
  const externalRequests = [];
  let largestEventPage = 0;
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.hostname !== "127.0.0.1") externalRequests.push(request.url());
  });
  page.on("response", async (response) => {
    if (response.url().includes("/api/v1/sessions/current/events")) {
      const body = await response.json();
      largestEventPage = Math.max(largestEventPage, body.events.length);
    }
  });

  await page.goto("/");
  await expect(page.getByRole("heading", { name: "BeamTrace" })).toBeVisible();
  await expect(page.getByText("80 visible / 1000000 total")).toBeVisible();
  await expect(page.locator("tbody tr")).toHaveCount(80);
  expect(largestEventPage).toBeLessThanOrEqual(200);
  expect(externalRequests).toEqual([]);

  await page.getByRole("button", { name: "Live" }).click();
  await expect(page.locator("main")).toHaveAttribute("data-mode", "live");

  await page.keyboard.press("Control+k");
  await expect(page.getByRole("dialog", { name: "Command palette" })).toBeVisible();
  await page.getByRole("button", { name: "Compare saved traces" }).click();
  await expect(page.locator("main")).toHaveAttribute("data-mode", "compare");

  await page.getByRole("searchbox", { name: "Search events" }).fill("needle");
  await expect(page.getByText("1 visible / 1 total")).toBeVisible();
  await expect(page.locator("tbody tr")).toHaveCount(1);
  await page.getByRole("button", { name: "needle-1" }).click();
  await expect(page.getByText("Event ID").locator(".." )).toContainText("needle-1");
});

test("workspace has no serious accessibility violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce", colorScheme: "dark" });
  await page.goto("/");
  await expect(page.locator("tbody tr")).toHaveCount(80);
  const results = await new AxeBuilder({ page }).analyze();
  const serious = results.violations.filter(({ impact }) =>
    impact === "serious" || impact === "critical"
  );
  expect(serious).toEqual([]);
});

test("paging avoids long main-thread stalls", async ({ page }) => {
  await page.addInitScript(() => {
    globalThis.__beamtraceLongTasks = [];
    new PerformanceObserver((items) => {
      for (const item of items.getEntries()) {
        globalThis.__beamtraceLongTasks.push(item.duration);
      }
    }).observe({ type: "longtask", buffered: true });
  });
  await page.goto("/");
  await expect(page.locator("tbody tr")).toHaveCount(80);
  for (let pageNumber = 0; pageNumber < 8; pageNumber += 1) {
    await page.getByRole("button", { name: "Next" }).click();
    await expect(page.locator(".minimap-window")).toHaveAttribute(
      "data-start",
      String((pageNumber + 1) * 80),
    );
  }
  const longest = await page.evaluate(() =>
    Math.max(0, ...globalThis.__beamtraceLongTasks),
  );
  expect(longest).toBeLessThan(250);
});
