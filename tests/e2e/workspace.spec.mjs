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
    if (response.url().includes("/api/v2/sessions/current/events")) {
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

  const canvas = page.locator("#causal-canvas");
  await expect(canvas).toHaveAttribute("data-edge-count", "3");
  await expect(canvas).toHaveAttribute(
    "data-edge-kinds",
    "process_order,sequential_message,spawned",
  );
  await expect(canvas).toHaveAttribute("data-inferred-edge-count", "1");
  await expect(canvas).toHaveAttribute("data-boundary-count", "1");
  await expect(canvas).toHaveAttribute("data-estimated-time-count", "1");
  expect(Number(await canvas.getAttribute("data-edge-count"))).toBeLessThan(79);

  await page.getByRole("button", { name: "event-2", exact: true }).click();
  const eventInspector = page.getByRole("complementary", { name: "Event inspector" });
  await expect(eventInspector).toContainText(
    "1774000000000000200 ns estimated [1774000000000000150, 1774000000000000250]",
  );
  await expect(eventInspector).toContainText(
    "Inferred · logical_actor_refinement_v2 · stable actor metadata",
  );
  await page.getByRole("button", { name: "event-4", exact: true }).click();
  await expect(eventInspector).toContainText(
    "spawned · child first event outside the visible observation",
  );

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
  await expect(eventInspector).toContainText("needle-1");
});

test("Compare aligns multiple traces and renders latency and occurrence statistics", async ({ page }) => {
  let submittedPaths = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname === "/api/v2/compare" && request.method() === "POST") {
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
  await expect(alignment).toContainText("90 ns estimated [80, 100]");
  await expect(alignment).toContainText("unique causal neighborhood");
  const statistics = page.getByRole("table", { name: "Multi-run branch statistics" });
  await expect(statistics).toContainText("p50 10 ns exact · 2 valid / 1 missing");
  await expect(statistics).toContainText(
    "p95 100 ns estimated [95, 105] · 2 valid / 1 missing",
  );
  await expect(statistics).toContainText("2/3 runs");
  await expect(
    page.getByLabel("First divergence causal path"),
  ).toContainText("event-1 → event-3");
  await expect(page.locator("#causal-canvas")).toHaveAttribute(
    "data-divergence-edge-count",
    "1",
  );
  expect(submittedPaths).toEqual([
    "baseline.beamtrace",
    "slow.beamtrace",
    "missing.beamtrace",
  ]);
});

test("CLI bootstrap compare input renders immediately and leaves no trace paths in history", async ({ page }) => {
  let submittedPaths = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname === "/api/v2/compare" && request.method() === "POST") {
      submittedPaths = request.postDataJSON().paths;
    }
  });

  await page.goto("/?compare=baseline.beamtrace%0Acandidate.beamtrace");
  await expect(page.locator("main")).toHaveAttribute("data-mode", "compare");
  await expect(page.getByRole("table", { name: "Accessible trace alignment table" }))
    .toContainText("candidate.beamtrace");
  expect(submittedPaths).toEqual(["baseline.beamtrace", "candidate.beamtrace"]);
  expect(new URL(page.url()).searchParams.has("compare")).toBe(false);
});

test("theme and mobile navigation retain every workspace function", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");

  const theme = page.getByRole("button", { name: "Change color theme" });
  await expect(theme).toContainText("System");
  await theme.click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await theme.click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await theme.click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "system");

  const mobileModes = page.getByRole("navigation", { name: "Mobile workspace mode" });
  await expect(mobileModes).toBeVisible();
  await mobileModes.getByRole("button", { name: "Compare" }).click();
  await expect(page.locator("main")).toHaveAttribute("data-mode", "compare");

  await page.getByText("Session navigator", { exact: true }).last().click();
  await expect(page.locator(".mobile-session-drawer")).toContainText("Attached BEAM session");
  await page.getByText("Inspector", { exact: true }).last().click();
  await expect(page.locator(".mobile-inspector-drawer")).toContainText("Compare inspector");

  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});

test("workspace has no accessibility violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce", colorScheme: "dark" });
  await page.goto("/");
  await expect(page.locator("tbody tr")).toHaveCount(80);
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});

test("Team trace library keeps raw content locked and pages permitted events", async ({ page }) => {
  const eventRequests = [];
  let holdRequest;
  let submittedPaths = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname === "/api/v2/compare" && request.method() === "POST") {
      submittedPaths = request.postDataJSON().paths;
    }
  });
  const teamEvent = {
    observation: {
      schema_version: 2,
      id: "team-event-7",
      root_id: "team-root",
      node: "orders@team",
      process: {
        physical: { node: "orders@team", pid: "<0.7.0>" },
        logical: { id: "checkout-worker", label: "Checkout worker" },
        identity_evidence: [],
      },
      local_instant: { offset_ns: 700, order: 7 },
      event: { kind: "send" },
      evidence: { kind: "exact" },
    },
    time: { kind: "unavailable", reason: "team archive has no clock phase" },
  };
  const traces = [
    {
      id: "trace-metadata",
      node: "orders@team",
      mfa: { module: "orders", function: "checkout", arity: 1 },
      privacy: "metadata",
      delivery_status: "delivered",
      event_count: 1,
      received_at_ms: 1_774_000_000_000,
      legal_hold: false,
      locked: false,
    },
    {
      id: "trace-raw-locked",
      node: "payments@team",
      mfa: { module: "payments", function: "charge", arity: 2 },
      privacy: "raw",
      delivery_status: "partial",
      event_count: 80,
      received_at_ms: 1_774_000_000_001,
      legal_hold: false,
      locked: true,
    },
    {
      id: "trace-metadata-2",
      node: "shipping@team",
      mfa: { module: "shipping", function: "dispatch", arity: 1 },
      privacy: "metadata",
      delivery_status: "delivered",
      event_count: 1,
      received_at_ms: 1_774_000_000_002,
      legal_hold: false,
      locked: false,
    },
  ];

  await page.route(/\/api\/v2\/traces(?:[/?].*)?$/, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (url.pathname === "/api/v2/traces") {
      await route.fulfill({ json: { traces, next_cursor: null } });
      return;
    }
    if (url.pathname === "/api/v2/traces/trace-metadata/events") {
      eventRequests.push(url.pathname);
      expect(url.searchParams.get("limit")).toBe("200");
      await route.fulfill({
        json: {
          trace_id: "trace-metadata",
          events: [teamEvent],
          next_cursor: null,
        },
      });
      return;
    }
    if (
      url.pathname === "/api/v2/traces/trace-metadata/hold" &&
      request.method() === "POST"
    ) {
      holdRequest = {
        accept: request.headers().accept,
        csrf: request.headers()["x-beamtrace-csrf"],
      };
      await route.fulfill({ json: { ...traces[0], legal_hold: true } });
      return;
    }
    eventRequests.push(url.pathname);
    await route.fulfill({ status: 500, json: { error: "unexpected_request" } });
  });

  await page.goto("/");
  await page.evaluate(() => { document.cookie = "beamtrace_csrf=e2e-token; SameSite=Strict"; });
  await page.getByRole("button", { name: "Team traces" }).click();

  const table = page.getByRole("table", { name: "Team traces" });
  await expect(table).toContainText("orders@team · orders:checkout/1");
  await expect(table).toContainText("payments@team · payments:charge/2");
  await expect(table.getByLabel("Content locked")).toBeVisible();

  await page.getByRole("button", { name: "trace-raw-locked", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Trace contents locked" })).toBeVisible();
  expect(eventRequests).toEqual([]);

  await page.getByRole("button", { name: "trace-metadata", exact: true }).click();
  await expect(page.getByRole("button", { name: "team-event-7" })).toBeVisible();
  expect(eventRequests).toEqual(["/api/v2/traces/trace-metadata/events"]);

  await page.getByRole("button", { name: "Place legal hold" }).click();
  await expect(
    page
      .getByRole("complementary", { name: "Team trace inspector" })
      .getByText("enabled", { exact: true }),
  ).toBeVisible();
  expect(holdRequest).toEqual({ accept: "application/json", csrf: "e2e-token" });

  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);

  await page.getByRole("button", {
    name: "Select trace-metadata for comparison",
  }).click();
  await page.getByRole("button", {
    name: "Select trace-metadata-2 for comparison",
  }).click();
  await expect(page.getByText("2 of 20 selected for comparison")).toBeVisible();
  await page.getByRole("button", { name: "Compare selected traces" }).click();
  await expect(page.locator("main")).toHaveAttribute("data-mode", "compare");
  await expect(page.getByRole("table", { name: "Accessible trace alignment table" }))
    .toContainText("team:trace-metadata-2");
  expect(submittedPaths).toEqual(["team:trace-metadata", "team:trace-metadata-2"]);
});

test("Live polls bounded process metadata and exposes evidence in DOM", async ({ page }) => {
  const liveLimits = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname === "/api/v2/live") {
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
  await page.getByText("Advanced", { exact: true }).click();
  await page.getByRole("textbox", { name: "AQL condition" }).fill(
    "arg.0.tag == order",
  );
  await page.getByRole("combobox", { name: "Framework preset" }).selectOption(
    "gen-server",
  );
  await page.getByRole("spinbutton", { name: "Max roots" }).fill("3");
  const armed = page.waitForResponse((response) => {
    const url = new URL(response.url());
    return url.pathname === "/api/v2/sessions/current/arm"
      && response.request().method() === "POST";
  });
  await page.getByRole("button", { name: "Arm capture" }).click();
  const armedPayload = await (await armed).json();
  expect(armedPayload).toMatchObject({ status: "armed" });
  await expect(
    page.getByLabel("Capture controls").locator(".capture-status"),
  ).toContainText(
    "Sealed · 1 events · sealed after 250ms quiet period · delivery verified",
  );
  await expect(page.getByRole("button", { name: "captured-root" })).toBeVisible();

  await page.getByRole("textbox", { name: "Save path" }).fill("dogfood.beamtrace");
  await page.getByRole("button", { name: "Save capture" }).click();
  await expect(page.getByText("Saved dogfood.beamtrace")).toBeVisible();
});
