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
      local_instant: types.LocalInstant(offset_ns: 100, order: 1),
      kind: types.Send(
        to: types.ProcessRef("shop@localhost", "<0.20.0>"),
        message: types.Tag("charge"),
        serial: types.SequenceSerial(previous: 0, current: 1),
      ),
      evidence: types.Exact,
    )

  let encoded = codec.encode_event(event)
  let assert Ok(decoded) = codec.decode_event(encoded)
  let assert Ok(graph) = dag.build([decoded])
  let assert [finding] =
    diagnostics.hot_senders([decoded], minimum_messages: 1)
  let assert diagnostics.CountValue(message_count) = finding.value

  io.println(
    "codec=round-trip dag_boundaries="
    <> { graph.boundaries |> list.length |> int.to_string }
    <> " diagnostic_messages="
    <> int.to_string(message_count),
  )
}
```

Run it on either supported target:

```sh
gleam run --target erlang
gleam run --target javascript --runtime nodejs
```

Both commands run the same portable analysis. The distribution consumer gate
also exercises the high-level façade, checked comparison, and MFA parser on
both targets.

## Validated façade and reusable comparison

Use the high-level `beamtrace` module when events enter your application. It
validates each event, builds the DAG once, and retains checked comparison
preparation behind one opaque `Trace` value:

```gleam
import beamtrace

let assert Ok(baseline) = beamtrace.from_events(baseline_events)
let assert Ok(first_run) = beamtrace.from_events(first_run_events)
let report = beamtrace.compare(baseline, first_run)
```

`beamtrace.decode_events` reports a one-based event number with its codec error,
while duplicate identifiers and cycles are typed graph errors. The façade works
unchanged on Erlang and JavaScript.

`diff.compare(left, right)` remains the convenient compatibility API. Strict
callers can use `diff.compare_checked`. `diff.prepare` now returns
`Result(PreparedTrace, DagError)`; compare a reusable baseline like this:

```gleam
import beamtrace/diff

let assert Ok(baseline) = diff.prepare(baseline_events)
let assert Ok(candidate) = diff.prepare(candidate_events)
let report = diff.compare_prepared(baseline, candidate)
```

Typed producers can call `codec.validate_manifest`, `codec.validate_event`,
`codec.validate_graph_segment`, and `codec.validate_clocks` before encoding.
These validators apply the same schema-v2 field rules as the decoding boundary
without allocating JSON and parsing it back into the same value.

## Modules

- `beamtrace/types` — capture specifications, node-relative events, structured outcomes, evidence, interval time, and privacy-safe term views
- `beamtrace` — validated high-level trace façade with one-time DAG construction
- `beamtrace/mfa` — validated `Module:function/arity` parsing and rendering
- `beamtrace/aql` — parsing, evaluation, and safe agent-side planning for BeamTrace Query Language
- `beamtrace/dag` and `beamtrace/merge` — causal graph validation and distributed partial-order merging
- `beamtrace/identity` — physical process and logical actor identity evidence
- `beamtrace/anomaly` and `beamtrace/diagnostics` — bounded Live analysis contracts
- `beamtrace/diff` and `beamtrace/stats` — PID-independent alignment, reusable prepared traces, and multi-run statistics
- `beamtrace/codec` and `beamtrace/protocol` — versioned trace and wire contracts

Every causal relationship is represented as exact evidence or as an inference carrying a method, reason, evidence events, observed values, and algorithm settings. External boundaries, integrity issues, ambiguity, and unavailable time remain explicit; the package does not emit confidence probabilities.

## Compatibility

`beamtrace_core` supports Gleam 1.18 or newer within the 1.x series and compiles for both Erlang and JavaScript targets.

## License

Licensed under either Apache-2.0 or MIT, at your option. Both complete licence texts are included in the package's `LICENSE` file.
