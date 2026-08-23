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

function event(index, query = "") {
  const needle = query ? `needle-${index}` : `event-${index}`;
  return {
    id: needle,
    root_id: "root-1",
    node: "fixture@host",
    process: {
      physical: { node: "fixture@host", pid: `<0.${index}.0>` },
      logical: { id: "checkout-worker", label: "Checkout worker" },
      evidence: [],
    },
    local_timestamp_ns: index * 100,
    event: { kind: index % 97 === 0 ? "exit" : "send" },
    evidence: { kind: "exact" },
  };
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1:4173");
  if (url.pathname === "/api/v1/sessions/current/events") {
    const start = Math.max(Number.parseInt(url.searchParams.get("start") ?? "0", 10), 0);
    const requested = Math.max(Number.parseInt(url.searchParams.get("limit") ?? "200", 10), 1);
    const limit = Math.min(requested, 200);
    const query = (url.searchParams.get("q") ?? "").trim();
    const total = query ? 1 : 1_000_000;
    const count = Math.max(Math.min(limit, total - start), 0);
    const events = Array.from({ length: count }, (_, offset) => event(start + offset + 1, query));
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
