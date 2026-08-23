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

  await page.getByRole("button", { name: "Capture", exact: true }).click();

  await page.getByRole("searchbox", { name: "Search events" }).fill("needle");
  await expect(page.getByText("1 visible / 1 total")).toBeVisible();
  await expect(page.locator("tbody tr")).toHaveCount(1);
  await page.getByRole("button", { name: "needle-1" }).click();
  await expect(page.getByText("Event ID").locator(".." )).toContainText("needle-1");
});

test("Compare aligns multiple traces and renders latency and occurrence statistics", async ({ page }) => {
  let submittedPaths = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname === "/api/v1/compare" && request.method() === "POST") {
      submittedPaths = request.postDataJSON().paths;
    }
  });

  await page.goto("/");
  await page.getByRole("button", { name: "Compare" }).click();
  await page.getByRole("textbox", { name: "Trace paths" }).fill(
    "baseline.beamtrace\nslow.beamtrace\nmissing.beamtrace",
  );
  await page.getByRole("button", { name: "Run comparison" }).click();

  const alignment = page.getByRole("table", { name: "Accessible trace alignment table" });
  await expect(alignment).toContainText("slow.beamtrace");
  await expect(alignment).toContainText("retry-branch");
  await expect(alignment).toContainText("+90 ns");
  const statistics = page.getByRole("table", { name: "Multi-run branch statistics" });
  await expect(statistics).toContainText("p50 10 ns · p95 100 ns");
  await expect(statistics).toContainText("2/3 runs");
  expect(submittedPaths).toEqual([
    "baseline.beamtrace",
    "slow.beamtrace",
    "missing.beamtrace",
  ]);
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

test("Live polls bounded process metadata and exposes evidence in DOM", async ({ page }) => {
  const liveLimits = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname === "/api/v1/live") {
      liveLimits.push(Number.parseInt(url.searchParams.get("limit"), 10));
    }
  });

  await page.goto("/");
  await page.getByRole("button", { name: "Live" }).click();
  const table = page.getByRole("table", { name: "Accessible live process table" });
  await expect(table.getByRole("row")).toHaveCount(2);
  await expect(table).toContainText("orders worker");
  await expect(table).toContainText("mailbox_growth");
  await expect(page.getByText(/Generation [1-9]/).first()).toBeVisible();

  await page.getByRole("button", { name: "orders worker" }).click();
  const inspector = page.getByRole("complementary", { name: "Process inspector" });
  await expect(inspector).toContainText("gen_server:loop/7");
  await expect(inspector).toContainText("EWMA exceeded baseline with hysteresis");
  await expect(inspector).toContainText("Inferred");
  expect(liveLimits.length).toBeGreaterThan(0);
  expect(Math.max(...liveLimits)).toBeLessThanOrEqual(200);
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

test("attached workspace arms, polls, loads, and saves a real capture", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("combobox", { name: "MFA trigger" }).fill("shop:checkout/1");
  await expect(page.locator("#mfa-candidates option")).toHaveAttribute(
    "value",
    "shop:checkout/1",
  );
  await page.getByRole("textbox", { name: "AQL condition" }).fill(
    "arg.0.tag == order",
  );
  await page.getByRole("combobox", { name: "Framework preset" }).selectOption(
    "gen-server",
  );
  await page.getByRole("spinbutton", { name: "Max roots" }).fill("3");
  await page.getByRole("button", { name: "Arm capture" }).click();

  await expect(page.getByText("Armed", { exact: true })).toBeVisible();
  await expect(
    page
      .getByLabel("Capture controls")
      .getByText("Ready · 1 events · complete", { exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "captured-root" })).toBeVisible();

  await page.getByRole("textbox", { name: "Save path" }).fill("dogfood.beamtrace");
  await page.getByRole("button", { name: "Save capture" }).click();
  await expect(page.getByText("Saved dogfood.beamtrace")).toBeVisible();
});
