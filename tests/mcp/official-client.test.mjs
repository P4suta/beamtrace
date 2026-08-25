// SPDX-License-Identifier: Apache-2.0 OR MIT
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import test, { after, before } from "node:test";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

const repositoryRoot = fileURLToPath(new URL("../..", import.meta.url));
const runtimeRoot = `${repositoryRoot}/packages/beamtrace_runtime`;
const beamtraceVersion = readFileSync(`${repositoryRoot}/version.txt`, "utf8").trim();
let fixtureRoot;
let fixturePath;

before(() => {
  fixtureRoot = mkdtempSync(join(tmpdir(), "beamtrace-mcp-client-"));
  fixturePath = join(fixtureRoot, "official-client.beamtrace");
  execFileSync(
    "gleam",
    ["run", "--", "demo", "--no-ui", "--out", fixturePath],
    { cwd: runtimeRoot, stdio: "pipe", timeout: 30_000 },
  );
});

after(() => {
  if (fixtureRoot) rmSync(fixtureRoot, { recursive: true, force: true });
});

async function connect(versionNegotiation) {
  const client = new Client(
    { name: "beamtrace-acceptance", version: "1.0.0" },
    versionNegotiation ? { versionNegotiation } : {},
  );
  const transport = new StdioClientTransport({
    command: "gleam",
    args: ["run", "--", "mcp"],
    cwd: runtimeRoot,
    stderr: "pipe",
  });
  let stderr = "";
  transport.stderr?.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  try {
    await client.connect(transport, { timeout: 30_000 });
    return { client, transport, stderr: () => stderr };
  } catch (error) {
    await transport.close().catch(() => {});
    throw new Error(`MCP connection failed: ${stderr}`, { cause: error });
  }
}

async function assertCatalog(connection, expectedEra, expectedVersion) {
  const { client, stderr } = connection;
  try {
    assert.equal(client.getProtocolEra(), expectedEra);
    assert.equal(client.getNegotiatedProtocolVersion(), expectedVersion);
    assert.deepEqual(client.getServerVersion(), {
      name: "beamtrace",
      version: beamtraceVersion,
    });
    const listed = await client.listTools();
    assert.deepEqual(
      listed.tools.map((tool) => tool.name),
      ["compare_summary", "event_get", "trace_search", "trace_overview"],
    );
    for (const tool of listed.tools) {
      assert.equal(tool.annotations?.readOnlyHint, true);
      assert.equal(tool.outputSchema?.type, "object");
    }

    const overview = await client.callTool({
      name: "trace_overview",
      arguments: { path: fixturePath },
    });
    assert.equal(overview.isError, false);
    assert.equal(typeof overview.structuredContent, "object");
    assert.ok(overview.structuredContent.event_count > 0);
    assert.deepEqual(
      JSON.parse(overview.content[0].text),
      overview.structuredContent,
    );

    const event = await client.callTool({
      name: "event_get",
      arguments: { path: fixturePath, index: 0 },
    });
    assert.equal(event.isError, false);
    assert.equal(typeof event.structuredContent.event, "object");
    assert.deepEqual(JSON.parse(event.content[0].text), event.structuredContent);

    const missing = await client.callTool({
      name: "event_get",
      arguments: {
        path: join(fixtureRoot, "missing.beamtrace"),
        index: 0,
      },
    });
    assert.equal(missing.isError, true);
    assert.deepEqual(missing.content, [
      { type: "text", text: "Event read failed" },
    ]);
  } catch (error) {
    throw new Error(`MCP catalog assertion failed: ${stderr()}`, { cause: error });
  } finally {
    await client.close();
  }
}

test("official client 2.0.0 supports the legacy initialize flow", async () => {
  await assertCatalog(await connect(), "legacy", "2025-11-25");
});

test("official client 2.0.0 auto-negotiates the modern flow", async () => {
  await assertCatalog(
    await connect({ mode: "auto", probe: { timeoutMs: 30_000 } }),
    "modern",
    "2026-07-28",
  );
});

test("official client 2.0.0 accepts an exact modern version pin", async () => {
  await assertCatalog(
    await connect({ mode: { pin: "2026-07-28" }, probe: { timeoutMs: 30_000 } }),
    "modern",
    "2026-07-28",
  );
});
