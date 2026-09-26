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
import beamtrace/event
import beamtrace/types
import gleam/int
import gleam/io
import gleam/list

pub fn main() {
  let sender = event.process(node: "shop@localhost", pid: "<0.10.0>")
  let sent =
    event.builder(root: "checkout-1", process: sender)
    |> event.at(offset_ns: 100, order: 1)
    |> event.send(
      id: "send-1",
      to: types.ProcessRef("shop@localhost", "<0.20.0>"),
      message: types.TagOnly("charge"),
      serial: event.serial(previous: 0, current: 1),
    )

  let encoded = codec.encode_event(sent)
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
import gleam/int
import gleam/io
import gleam/list
import gleam/result

pub fn summarize(
  baseline_lines: List(String),
  run_lines: List(String),
) -> String {
  let summary = {
    use baseline <- result.try(beamtrace.decode_events(baseline_lines))
    use run <- result.try(beamtrace.decode_events(run_lines))
    let report = beamtrace.compare(baseline, run)
    let findings = beamtrace.findings(run)
    Ok(
      int.to_string(report.changed)
      <> " changed actors, "
      <> int.to_string(list.length(findings))
      <> " findings",
    )
  }
  case summary {
    Ok(line) -> line
    Error(failure) -> beamtrace.error_message(failure)
  }
}

pub fn main() {
  io.println(summarize([], []))
}
```

`beamtrace.decode_events` reports a one-based event number with its codec error,
while duplicate identifiers and cycles are typed graph errors. Every error type
has a renderer: `beamtrace.error_message`, `codec.error_message`,
`dag.error_message`, and `mfa.error_message`. The façade works unchanged on
Erlang and JavaScript.

`codec.decode_event` requires BeamTrace's own canonical bytes; any re-serialised
JSON fails with `NonCanonicalJson`. `diff.compare` validates both causal DAGs
and returns the first `DagError` instead of comparing an invalid trace.
`diff.prepare` returns `Result(PreparedTrace, DagError)`; compare a reusable
baseline like this:

```gleam
import beamtrace/dag
import beamtrace/diff
import beamtrace/types
import gleam/list
import gleam/result

pub fn changed_against_baseline(
  baseline_events: List(types.TraceEvent),
  runs: List(List(types.TraceEvent)),
) -> Result(List(Int), dag.DagError) {
  use baseline <- result.try(diff.prepare(baseline_events))
  list.try_map(runs, fn(events) {
    use candidate <- result.try(diff.prepare(events))
    Ok(diff.compare_prepared(baseline, candidate).changed)
  })
}
```

Typed producers can call `codec.validate_manifest`, `codec.validate_event`,
`codec.validate_graph_segment`, and `codec.validate_clocks` before encoding.
These validators apply the same schema-v2 field rules as the decoding boundary
without allocating JSON and parsing it back into the same value.

## Examples

Every Gleam code block in this README is a complete module and is compiled on
both targets by the repository's snippet gate. Four runnable projects live in
the repository's [`examples/`](https://github.com/P4suta/beamtrace/tree/main/examples)
directory:

- `decode_and_compare` — build events, decode them through the validated facade, and compare two runs
- `build_events` — construct codec-valid events with `beamtrace/event` and round-trip them
- `query_language` — reject an AQL typo with a caret report and split a query into an agent predicate and residual
- `diagnostics_thresholds` — tune diagnostic thresholds through the facade

The distribution consumer gate additionally runs
[`fixtures/hex_consumer.gleam`](https://github.com/P4suta/beamtrace/blob/main/fixtures/hex_consumer.gleam)
against the published package surface on both targets.

## Modules

- `beamtrace/types` — capture specifications, node-relative events, structured outcomes, evidence, interval time, and privacy-safe term views
- `beamtrace` — validated high-level trace façade with one-time DAG construction
- `beamtrace/event` — pipe-shaped builder for constructing trace events without boilerplate
- `beamtrace/mfa` — validated `Module:function/arity` parsing and rendering
- `beamtrace/aql` — parsing, evaluation, and safe agent-side planning for BeamTrace Query Language
- `beamtrace/dag` and `beamtrace/merge` — causal graph validation and distributed partial-order merging
- `beamtrace/identity` — physical process and logical actor identity evidence
- `beamtrace/anomaly` and `beamtrace/diagnostics` — bounded live-sampling alerts and offline diagnostics
- `beamtrace/diff` and `beamtrace/stats` — PID-independent alignment, reusable prepared traces, and multi-run statistics
- `beamtrace/codec` — canonical schema-v2 encoding, decoding, typed validation, and structured JSON builders for embedding events in your own documents
- `beamtrace/privacy` — metadata-safe term shaping and deterministic rendering
- `beamtrace/protocol` — semantic labels (`$gen_call`, `$gen_cast`, `DOWN`, `EXIT`, …) for redacted term views

Every causal relationship is represented as exact evidence or as an inference carrying a method, reason, evidence events, observed values, and algorithm settings. External boundaries, integrity issues, ambiguity, and unavailable time remain explicit; the package does not emit confidence probabilities.

## Compatibility

`beamtrace_core` supports Gleam 1.18 or newer within the 1.x series and compiles for both Erlang and JavaScript targets.

## License

Licensed under either Apache-2.0 or MIT, at your option. Both complete licence texts are included in the package's `LICENSE` file.
