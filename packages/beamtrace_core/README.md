<!-- SPDX-License-Identifier: Apache-2.0 OR MIT -->
# beamtrace_core

Target-independent causal trace contracts and analysis for the BeamTrace BEAM causal workbench.

This package contains the portable Gleam data model used by Erlang and JavaScript clients. It does not attach to a BEAM node or enable tracing by itself.

## Installation

Add the package to a Gleam project:

```sh
gleam add beamtrace_core
```

API documentation is generated at [hexdocs.pm/beamtrace_core](https://hexdocs.pm/beamtrace_core/). The source for each documented definition links back to the `packages/beamtrace_core` path in the BeamTrace monorepo.

## Codec, DAG, and diagnostics example

This complete `src/your_app.gleam` example round-trips an event through the
public codec, builds its causal graph, and runs a bounded diagnostic:

```gleam
import beamtrace/codec
import beamtrace/dag
import beamtrace/diagnostics
import beamtrace/types
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}

pub fn main() {
  let sender =
    types.ProcessIdentity(
      physical: types.ProcessRef("shop@localhost", "<0.10.0>"),
      logical: None,
      evidence: [],
    )
  let event =
    types.TraceEvent(
      id: "send-1",
      root_id: "checkout-1",
      node: "shop@localhost",
      process: sender,
      local_timestamp_ns: 100,
      kind: types.Send(
        to: types.ProcessRef("shop@localhost", "<0.20.0>"),
        message: types.Tag("charge"),
        serial: 1,
      ),
      evidence: types.Exact,
    )

  let encoded = codec.encode_event(event)
  let assert Ok(decoded) = codec.decode_event(encoded)
  let assert Ok(graph) = dag.build([decoded])
  let assert [finding] =
    diagnostics.hot_senders([decoded], minimum_messages: 1)

  io.println(
    "codec=round-trip dag_boundaries="
    <> { graph.boundaries |> list.length |> int.to_string }
    <> " diagnostic_messages="
    <> int.to_string(finding.value),
  )
}
```

Run it on either supported target:

```sh
gleam run --target erlang
gleam run --target javascript --runtime nodejs
```

Both commands print
`codec=round-trip dag_boundaries=1 diagnostic_messages=1`.

## Modules

- `beamtrace/types` — capture specifications, trace events, evidence, completeness, and privacy-safe term views
- `beamtrace/aql` — parsing, evaluation, and safe agent-side planning for BeamTrace Query Language
- `beamtrace/dag` and `beamtrace/merge` — causal graph validation and distributed partial-order merging
- `beamtrace/identity` — physical process and logical actor identity evidence
- `beamtrace/anomaly` and `beamtrace/diagnostics` — bounded Live analysis contracts
- `beamtrace/diff` and `beamtrace/stats` — PID-independent alignment and multi-run statistics
- `beamtrace/codec` and `beamtrace/protocol` — versioned trace and wire contracts

Every causal relationship is represented as exact evidence or as an inference carrying a reason and confidence. External boundaries and missing observations remain explicit.

## Compatibility

`beamtrace_core` supports Gleam 1.18 or newer within the 1.x series and compiles for both Erlang and JavaScript targets.

## License

Licensed under either Apache-2.0 or MIT, at your option. Both complete licence texts are included in the package's `LICENSE` file.
