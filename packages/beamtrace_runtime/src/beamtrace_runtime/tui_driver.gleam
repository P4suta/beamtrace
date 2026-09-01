// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/types
import beamtrace_runtime/capture
import beamtrace_runtime/capture_session
import beamtrace_runtime/cli
import beamtrace_runtime/live
import beamtrace_runtime/local_auth
import beamtrace_runtime/storage
import beamtrace_tui/adapter
import beamtrace_tui/model
import beamtrace_tui/session
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string

pub fn new(
  store: capture_session.Store,
  tool_version: String,
) -> session.Driver {
  session.Driver(
    attach: fn(node) { attach(store, node) },
    arm: fn(trigger) { arm(store, trigger) },
    poll: fn() { poll(store) },
    save: fn(path) { save(store, tool_version, path) },
    cancel: fn() { capture_session.cancel(store) |> control_result },
    live_poll: fn() { live_poll(store) },
  )
}

fn live_poll(store: capture_session.Store) -> session.LiveState {
  case capture_session.nodes(store) {
    [] -> session.LiveUnavailable("target_not_owned")
    [node, ..] ->
      case
        capture_session.live_snapshot_at(
          store,
          node,
          200,
          local_auth.now_ms(),
          500,
        )
      {
        Error(error) -> session.LiveUnavailable(error_name(error))
        Ok(snapshot) -> {
          let findings = live.analyze(snapshot.previous, snapshot.samples)
          let graphs = live.topology_graphs(snapshot.samples)
          let rows =
            list.map(snapshot.samples, fn(sample) {
              live_event(sample, findings, snapshot.generation)
            })
          let summary =
            int.to_string(list.length(snapshot.samples))
            <> " process · supervision "
            <> int.to_string(list.length(graphs.supervision))
            <> " · spawn "
            <> int.to_string(list.length(graphs.spawn))
            <> " · links "
            <> int.to_string(list.length(graphs.links))
          session.LiveReady(rows, snapshot.generation, summary)
        }
      }
  }
}

fn live_event(
  sample: live.ProcessSample,
  findings: List(live.LiveFinding),
  generation: Int,
) -> model.Event {
  case list.find(findings, fn(finding) { finding.pid == sample.pid }) {
    Error(_) ->
      model.Event(
        sample.pid,
        sample.label,
        sample.status
          <> " · mailbox="
          <> int.to_string(sample.mailbox_len)
          <> " · memory="
          <> int.to_string(sample.memory_bytes)
          <> " · reductions="
          <> int.to_string(sample.reductions),
        "Exact sample",
        generation,
        False,
      )
    Ok(finding) ->
      model.Event(
        sample.pid,
        sample.label,
        finding.kind <> " · " <> finding.summary,
        evidence_text(finding.evidence),
        generation,
        True,
      )
  }
}

fn evidence_text(evidence: types.Evidence) -> String {
  case evidence {
    types.Exact -> "Exact"
    types.Inferred(inference) ->
      "Inferred · " <> inference.method <> " · " <> inference.reason
  }
}

fn attach(store: capture_session.Store, node: String) -> Result(Nil, String) {
  case list.contains(capture_session.nodes(store), node) {
    True -> Ok(Nil)
    False -> Error("target_not_owned")
  }
}

fn arm(store: capture_session.Store, source: String) -> Result(Nil, String) {
  case cli.parse_mfa(source) {
    Error(cli.ParseError(message, _)) -> Error(message)
    Ok(cli.Mfa(module, function, arity)) ->
      capture_session.arm(
        store,
        capture_session.ArmSpec(
          trigger: types.Mfa(module, function, arity),
          where_aql: None,
          capture_window_ms: 30_000,
          drain_timeout_ms: 10_000,
          budget: capture.default_budget(),
          max_roots: 1,
          preset: types.Generic,
        ),
      )
      |> control_result
  }
}

fn poll(store: capture_session.Store) -> session.CaptureState {
  case capture_session.status(store) {
    capture_session.Idle -> session.SessionIdle
    capture_session.Armed -> session.SessionArmed
    capture_session.Cancelling -> session.SessionCancelling
    capture_session.Failed(reason) -> session.SessionFailed(reason)
    capture_session.Ready(_, outcome_summary) ->
      case capture_session.result(store) {
        Ok(result) ->
          session.SessionReady(
            adapter.from_trace(result.events),
            outcome_summary,
          )
        Error(error) -> session.SessionFailed(error_name(error))
      }
  }
}

fn save(
  store: capture_session.Store,
  tool_version: String,
  path: String,
) -> Result(Nil, String) {
  case string.ends_with(string.lowercase(path), ".beamtrace") {
    False -> Error("save_path_must_end_in_.beamtrace")
    True ->
      case capture_session.result(store) {
        Error(error) -> Error(error_name(error))
        Ok(result) -> {
          let manifest =
            codec.Manifest(
              schema_version: codec.schema_version,
              tool_version: tool_version,
              capture_id: capture_id(),
              nodes: capture_session.nodes(store),
              outcome: result.outcome,
              privacy: types.Metadata,
            )
          case
            storage.save_with_clocks(
              path,
              manifest,
              result.events,
              result.clocks,
            )
          {
            Ok(Nil) -> Ok(Nil)
            Error(_) -> Error("archive_write_failed")
          }
        }
      }
  }
}

fn control_result(
  result: Result(Nil, capture_session.SessionError),
) -> Result(Nil, String) {
  case result {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error(error_name(error))
  }
}

fn error_name(error: capture_session.SessionError) -> String {
  case error {
    capture_session.CaptureAlreadyRunning -> "capture_already_running"
    capture_session.CaptureNotReady -> "capture_not_ready"
    capture_session.CaptureTimeout -> "capture_timeout"
    capture_session.SessionClosed -> "session_closed"
    capture_session.InvalidSessionRequest(reason) -> reason
    capture_session.CaptureFailed(reason) -> reason
  }
}

@external(erlang, "beamtrace_cli_ffi", "capture_id")
fn capture_id() -> String
