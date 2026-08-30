<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# MCP reference

Start the stdio server with:

```sh
beamtrace mcp
```

It exposes bounded, read-only, idempotent tools with JSON Schema 2020-12 input
and output contracts:

- `trace_overview` — archive version, nodes, privacy, outcome, ranges, and kinds;
- `event_get` — one event by zero-based index;
- `trace_search` — bounded metadata search, at most 200 returned events;
- `compare_summary` — logical actor and causal-shape comparison of two archives.

The server does not attach, capture, mutate a process, return raw payloads, or
open the network. Invalid archive, index, query, and graph conditions are typed
tool errors.
