// SPDX-License-Identifier: Apache-2.0 OR MIT
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";

const root = resolve("packages/beamtrace_web/dist");
const mime = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
]);

let capturePhase = "idle";
let capturePolls = 0;
let liveGeneration = 0;

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function event(index, query = "") {
  const needle = query ? `needle-${index}` : `event-${index}`;
  return {
    observation: {
      schema_version: 2,
      id: needle,
      root_id: "root-1",
      node: "fixture@host",
      process: {
        physical: { node: "fixture@host", pid: `<0.${index}.0>` },
        logical: { id: "checkout-worker", label: "Checkout worker" },
        identity_evidence: [],
      },
      local_instant: { offset_ns: index * 100, order: index },
      event: { kind: index % 97 === 0 ? "exit" : "send" },
      evidence: index === 2
        ? {
            kind: "inferred",
            inference: {
              method: "logical_actor_refinement_v2",
              reason: "stable actor metadata",
              inputs: [{ kind: "event", event_id: "event-1" }],
            },
          }
        : { kind: "exact" },
    },
    time: index === 2
      ? {
          kind: "estimated",
          value_ns: "1774000000000000200",
          lower_ns: "1774000000000000150",
          upper_ns: "1774000000000000250",
        }
      : { kind: "exact", value_ns: String(1774000000000000000n + BigInt(index * 100)) },
  };
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1:4173");
  if (url.pathname === "/api/v2/live" && request.method === "GET") {
    liveGeneration += 1;
    const evidence = {
      kind: "inferred",
      inference: {
        method: "ewma_hysteresis_v2",
        reason: "EWMA exceeded baseline with hysteresis",
        inputs: [
          { kind: "observed", name: "mailbox_len", value: "50" },
          { kind: "setting", name: "hysteresis", value: "enabled" },
        ],
      },
    };
    const payload = {
      node: "fixture@host",
      generation: liveGeneration,
      sampled_at_ms: Date.now(),
      next_offset: liveGeneration,
      samples: [{
        node: "fixture@host",
        pid: "<0.42.0>",
        label: "orders worker",
        registered_name: "orders",
        process_label: "orders worker",
        initial_call: "orders_worker:init/1",
        mailbox_len: 50,
        memory_bytes: 10000,
        reductions: 1000 + liveGeneration,
        heap_words: 100,
        total_heap_words: 200,
        link_count: 1,
        status: "waiting",
        current_function: "gen_server:loop/7",
        links: ["<0.7.0>"],
        ancestors: ["orders_sup"],
      }],
      findings: [{
        pid: "<0.42.0>",
        label: "orders worker",
        kind: "mailbox_growth",
        summary: "mailbox is growing above its baseline",
        evidence,
      }],
      topology: {
        supervision: [{
          from: "orders_sup",
          to: "<0.42.0>",
          evidence: {
            kind: "inferred",
            inference: {
              method: "proc_lib_ancestor_v2",
              reason: "proc_lib ancestor metadata",
              inputs: [{ kind: "observed", name: "ancestor", value: "orders_sup" }],
            },
          },
        }],
        spawn: [],
        links: [{
          from: "<0.7.0>",
          to: "<0.42.0>",
          evidence: { kind: "exact" },
        }],
      },
    };
    response.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(JSON.stringify(payload));
    return;
  }
  if (url.pathname === "/api/v2/compare" && request.method === "POST") {
    const body = await readJson(request);
    if (!Array.isArray(body.paths) || body.paths.length < 2 || body.paths.length > 20) {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "invalid_paths" }));
      return;
    }
    response.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(JSON.stringify({
      baseline: body.paths[0],
      run_count: body.paths.length,
      reports: body.paths.slice(1).map((path) => ({
        path,
        added: 1,
        removed: 0,
        changed: 0,
        ambiguity_count: 1,
        first_divergence: {
          left_frontier: ["event-1"],
          right_frontier: ["event-3"],
          causal_path: ["event-1", "event-3"],
        },
        items: [
          {
            status: "matched",
            left_id: "left-send",
            right_id: "right-send",
            latency_delta: {
              kind: "estimated",
              value_ns: "90",
              lower_ns: "80",
              upper_ns: "100",
            },
          },
          {
            status: "added",
            right_id: "retry-branch",
            reason: "unique causal neighborhood",
          },
        ],
      })),
      statistics: [{
        signature: "orders|send:tag:work",
        p50: {
          estimate: { kind: "exact", value_ns: "10" },
          valid_samples: 2,
          missing_samples: 1,
        },
        p95: {
          estimate: {
            kind: "estimated",
            value_ns: "100",
            lower_ns: "95",
            upper_ns: "105",
          },
          valid_samples: 2,
          missing_samples: 1,
        },
        occurrences: 2,
        total_runs: body.paths.length,
      }],
    }));
    return;
  }
  if (url.pathname === "/api/v2/sessions/current" && request.method === "GET") {
    if (capturePhase === "armed") {
      capturePolls += 1;
      if (capturePolls >= 3) capturePhase = "ready";
    }
    const payload = capturePhase === "ready"
      ? {
          status: "sealed",
          event_count: 1,
          outcome: {
            end: { kind: "quiet_period", quiet_ms: 250 },
            issues: [],
            receipts: [{
              node: "fixture@host",
              final_batch_sequence: 1,
              event_count: 1,
              byte_count: 128,
            }],
          },
          delivery_verified: true,
          clocks: { schema_version: 2, unix_anchor_ns: "1774000000000000000", nodes: [] },
        }
      : { status: capturePhase };
    response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    response.end(JSON.stringify(payload));
    return;
  }
  if (url.pathname === "/api/v2/targets/current/mfas" && request.method === "GET") {
    const query = (url.searchParams.get("q") ?? "").toLowerCase();
    const candidates = "shop:checkout/1".includes(query)
      ? [{
          node: "fixture@host",
          module: "shop",
          function: "checkout",
          arity: 1,
          mfa: "shop:checkout/1",
        }]
      : [];
    response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    response.end(JSON.stringify({ candidates }));
    return;
  }
  if (url.pathname === "/api/v2/sessions/current/arm" && request.method === "POST") {
    const body = await readJson(request);
    if (body.trigger !== "shop:checkout/1") {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "invalid_trigger" }));
      return;
    }
    if (
      body.where !== "arg.0.tag == order" ||
      body.preset !== "gen-server" ||
      body.max_roots !== 3
    ) {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "capture_spec_not_forwarded" }));
      return;
    }
    capturePhase = "armed";
    capturePolls = 0;
    response.writeHead(202, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "armed" }));
    return;
  }
  if (url.pathname === "/api/v2/sessions/current/cancel" && request.method === "POST") {
    capturePhase = "cancelling";
    response.writeHead(202, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "cancelling" }));
    return;
  }
  if (url.pathname === "/api/v2/sessions/current/save" && request.method === "POST") {
    const body = await readJson(request);
    if (capturePhase !== "ready" || typeof body.path !== "string") {
      response.writeHead(409, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "capture_not_ready" }));
      return;
    }
    response.writeHead(201, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "saved", path: body.path }));
    return;
  }
  if (url.pathname === "/api/v2/sessions/current/graph" && request.method === "GET") {
    response.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(JSON.stringify({
      schema_version: 2,
      event_ids: ["event-1", "event-2", "event-3", "event-4", "event-5", "event-6"],
      edges: [
        {
          from: "event-1",
          to: "event-3",
          kind: { kind: "process_order" },
          evidence: { kind: "exact" },
        },
        {
          from: "event-3",
          to: "event-4",
          kind: { kind: "sequential_message", serial: { previous: 8, current: 9 } },
          evidence: {
            kind: "inferred",
            inference: {
              method: "legacy_boundary_v2",
              reason: "one endpoint was migrated",
              inputs: [{ kind: "event", event_id: "event-3" }],
            },
          },
        },
        {
          from: "event-5",
          to: "event-6",
          kind: { kind: "spawned" },
          evidence: { kind: "exact" },
        },
      ],
      boundaries: [{
        event_id: "event-4",
        kind: { kind: "spawned" },
        reason: "child first event outside the visible observation",
      }],
    }));
    return;
  }
  if (url.pathname === "/api/v2/sessions/current/events") {
    const start = Math.max(Number.parseInt(url.searchParams.get("start") ?? "0", 10), 0);
    const requested = Math.max(Number.parseInt(url.searchParams.get("limit") ?? "200", 10), 1);
    const limit = Math.min(requested, 200);
    const query = (url.searchParams.get("q") ?? "").trim();
    const total = capturePhase === "ready" ? (query ? 0 : 1) : (query ? 1 : 1_000_000);
    const count = Math.max(Math.min(limit, total - start), 0);
    const events = capturePhase === "ready"
      ? (count === 1
          ? [{
              ...event(1),
              observation: {
                ...event(1).observation,
                id: "captured-root",
                root_id: "captured-root",
              },
            }]
          : [])
      : Array.from({ length: count }, (_, offset) => event(start + offset + 1, query));
    response.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(JSON.stringify({ start, limit, total, events }));
    return;
  }

  const pathname = url.pathname === "/" ? "/index.html" : url.pathname;
  const candidate = normalize(join(root, pathname));
  if (!candidate.startsWith(root)) {
    response.writeHead(404).end();
    return;
  }
  try {
    const info = await stat(candidate);
    if (!info.isFile()) throw new Error("not a file");
    response.writeHead(200, {
      "content-type": mime.get(extname(candidate)) ?? "application/octet-stream",
      "cache-control": "no-store",
    });
    createReadStream(candidate).pipe(response);
  } catch {
    response.writeHead(404).end();
  }
});

server.listen(4173, "127.0.0.1");

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
