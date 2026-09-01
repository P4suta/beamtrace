//// High-level, target-independent trace entry point.
////
//// Construction validates every event and creates the causal DAG and reusable
//// comparison preparation once. Failures retain either the one-based event
//// number or the typed DAG error. Construction is O((n + e) log n); accessors
//// are O(1). The same calls compile on Erlang and JavaScript:
////
//// ```gleam
//// let assert Ok(trace) = beamtrace.from_events(events)
//// let graph = beamtrace.graph(trace)
//// ```

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/dag
import beamtrace/diagnostics
import beamtrace/diff
import beamtrace/types
import gleam/int
import gleam/list

/// A validated trace whose causal graph and comparison preparation were built
/// together. The representation is opaque so callers cannot accidentally pair
/// events with a graph derived from different input.
pub opaque type Trace {
  Trace(
    trace_events: List(types.TraceEvent),
    causal_graph: dag.CausalGraph,
    prepared_trace: diff.PreparedTrace,
    validated_event_count: Int,
  )
}

/// Failure while constructing a validated `Trace`.
///
/// Event numbers are one-based so they map directly to JSONL line numbers.
pub type TraceError {
  EventError(event_number: Int, cause: codec.CodecError)
  GraphError(cause: dag.DagError)
}

/// Validate typed events and construct their DAG exactly once.
///
/// The first invalid event is returned with its one-based position. Duplicate
/// identifiers and cycles are graph errors. Runtime is O((n + e) log n).
pub fn from_events(
  trace_events: List(types.TraceEvent),
) -> Result(Trace, TraceError) {
  case validate_events(trace_events, 1) {
    Error(error) -> Error(error)
    Ok(Nil) -> build_trace(trace_events)
  }
}

/// Decode canonical event JSON and construct a validated DAG exactly once.
///
/// Each string is one event (for example, one JSONL line). The decoder rejects
/// non-canonical v2 JSON and reports the one-based failing event number.
pub fn decode_events(sources: List(String)) -> Result(Trace, TraceError) {
  case decode_event_list(sources, 1, []) {
    Error(error) -> Error(error)
    Ok(trace_events) -> build_trace(trace_events)
  }
}

/// Return the validated events in their original order. This is O(1).
pub fn events(trace: Trace) -> List(types.TraceEvent) {
  trace.trace_events
}

/// Return the validated causal graph. This is O(1).
pub fn graph(trace: Trace) -> dag.CausalGraph {
  trace.causal_graph
}

/// Return cached comparison preparation. This is O(1); no DAG is rebuilt.
/// Unlike `diff.prepare`, it cannot fail because the trace is already
/// validated.
pub fn prepared(trace: Trace) -> diff.PreparedTrace {
  trace.prepared_trace
}

/// Compare two validated traces using their cached preparation.
pub fn compare(left: Trace, right: Trace) -> diff.DiffReport {
  diff.compare_prepared(left.prepared_trace, right.prepared_trace)
}

/// Render a stable, user-facing explanation without exposing runtime inspect
/// output. This is intended for both Erlang and JavaScript consumers.
pub fn error_message(error: TraceError) -> String {
  case error {
    EventError(number, cause) ->
      "event " <> int.to_string(number) <> ": " <> codec.error_message(cause)
    GraphError(cause) -> dag.error_message(cause)
  }
}

/// Return the number of validated events. This is O(1).
pub fn event_count(trace: Trace) -> Int {
  trace.validated_event_count
}

/// Run the offline diagnostics with their documented default thresholds: hot
/// senders and fan-in from 100 messages, queue waits above 100 ms, and
/// restart chains with gaps of at most 1 s. Dangling calls need the capture
/// outcome and a reference time, so call `diagnostics.dangling_calls`
/// directly. Each finding carries its evidence events; none carries a
/// confidence number.
pub fn findings(trace: Trace) -> List(diagnostics.Finding) {
  let events = trace.trace_events
  list.flatten([
    diagnostics.hot_senders(events, minimum_messages: 100),
    diagnostics.fan_in(events, minimum_senders: 100),
    diagnostics.queue_waits(events, minimum_ns: 100_000_000),
    diagnostics.restart_chains(events, maximum_gap_ns: 1_000_000_000),
  ])
}

fn validate_events(
  trace_events: List(types.TraceEvent),
  event_number: Int,
) -> Result(Nil, TraceError) {
  case trace_events {
    [] -> Ok(Nil)
    [event, ..rest] ->
      case codec.validate_event(event) {
        Error(error) -> Error(EventError(event_number, error))
        Ok(Nil) -> validate_events(rest, event_number + 1)
      }
  }
}

fn decode_event_list(
  sources: List(String),
  event_number: Int,
  accumulator: List(types.TraceEvent),
) -> Result(List(types.TraceEvent), TraceError) {
  case sources {
    [] -> Ok(reverse(accumulator, []))
    [source, ..rest] ->
      case codec.decode_event(source) {
        Error(error) -> Error(EventError(event_number, error))
        Ok(event) ->
          decode_event_list(rest, event_number + 1, [event, ..accumulator])
      }
  }
}

fn reverse(remaining: List(a), accumulator: List(a)) -> List(a) {
  case remaining {
    [] -> accumulator
    [item, ..rest] -> reverse(rest, [item, ..accumulator])
  }
}

fn build_trace(
  trace_events: List(types.TraceEvent),
) -> Result(Trace, TraceError) {
  case diff.prepare_with_graph(trace_events) {
    Error(error) -> Error(GraphError(error))
    Ok(#(causal_graph, prepared_trace)) ->
      Ok(Trace(
        trace_events,
        causal_graph,
        prepared_trace,
        list.length(trace_events),
      ))
  }
}
