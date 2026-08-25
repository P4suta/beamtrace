// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/capture
import beamtrace_runtime/live
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type Store

pub type ArmSpec {
  ArmSpec(
    trigger: types.Mfa,
    where_aql: Option(String),
    capture_window_ms: Int,
    drain_timeout_ms: Int,
    budget: capture.Budget,
    max_roots: Int,
    preset: types.Preset,
  )
}

pub type Status {
  Idle
  Armed
  Cancelling
  Ready(event_count: Int, outcome_summary: String)
  Failed(reason: String)
}

pub type SessionError {
  CaptureAlreadyRunning
  CaptureNotReady
  CaptureTimeout
  SessionClosed
  InvalidSessionRequest(reason: String)
  CaptureFailed(reason: String)
}

pub type Backend =
  fn(ArmSpec) -> Result(capture.CaptureResult, String)

pub type SearchBackend =
  fn(String, String, Int) -> Result(List(capture.MfaCandidate), String)

pub type LiveBackend =
  fn(String, Int, Int) -> Result(#(List(live.ProcessSample), Int), String)

pub type LiveSnapshot {
  LiveSnapshot(
    generation: Int,
    sampled_at_ms: Int,
    samples: List(live.ProcessSample),
    previous: List(live.ProcessSample),
    next_offset: Int,
  )
}

/// Create a local-only capture owner. Distribution cookies remain captured by
/// this closure and are never added to the HTTP context or serialized state.
pub fn new(nodes: List(String), cookie: String) -> Store {
  start(
    nodes,
    fn(spec) { capture_nodes(nodes, cookie, spec) },
    fn(node, query, limit) { capture.search_mfas(node, cookie, query, limit) },
    fn(node, offset, limit) { live.remote_sample(node, cookie, offset, limit) },
  )
}

/// Test seam for exercising the asynchronous ownership contract without a
/// distribution node. Production callers should use `new`.
pub fn new_with_backend(backend: Backend) -> Store {
  new_with_backend_for_nodes([], backend)
}

pub fn new_with_backend_for_nodes(
  nodes: List(String),
  backend: Backend,
) -> Store {
  new_with_backends_for_nodes(nodes, backend, fn(_node, _query, _limit) {
    Error("mfa_search_unavailable")
  })
}

pub fn new_with_backends_for_nodes(
  nodes: List(String),
  backend: Backend,
  search_backend: SearchBackend,
) -> Store {
  start(nodes, backend, search_backend, fn(_node, _offset, _limit) {
    Error("live_sampling_unavailable")
  })
}

pub fn new_with_live_backend_for_nodes(
  nodes: List(String),
  backend: Backend,
  live_backend: LiveBackend,
) -> Store {
  start(
    nodes,
    backend,
    fn(_node, _query, _limit) { Error("mfa_search_unavailable") },
    live_backend,
  )
}

pub fn arm(store: Store, spec: ArmSpec) -> Result(Nil, SessionError) {
  case valid_spec(spec) {
    Error(reason) -> Error(InvalidSessionRequest(reason))
    Ok(Nil) -> arm_raw(store, spec) |> map_control_result
  }
}

pub fn status(store: Store) -> Status {
  status_raw(store)
}

pub fn await(
  store: Store,
  timeout_ms: Int,
) -> Result(capture.CaptureResult, SessionError) {
  case timeout_ms > 0 {
    False -> Error(InvalidSessionRequest("timeout_must_be_positive"))
    True ->
      case await_raw(store, timeout_ms) {
        Ok(result) -> Ok(result)
        Error("timeout") -> Error(CaptureTimeout)
        Error("capture_not_ready") -> Error(CaptureNotReady)
        Error("session_closed") -> Error(SessionClosed)
        Error(reason) -> Error(CaptureFailed(reason))
      }
  }
}

pub fn result(store: Store) -> Result(capture.CaptureResult, SessionError) {
  case result_raw(store) {
    Ok(result) -> Ok(result)
    Error("capture_not_ready") -> Error(CaptureNotReady)
    Error("session_closed") -> Error(SessionClosed)
    Error(reason) -> Error(CaptureFailed(reason))
  }
}

pub fn nodes(store: Store) -> List(String) {
  nodes_raw(store)
}

pub fn search_mfas(
  store: Store,
  node: String,
  query: String,
  limit: Int,
) -> Result(List(capture.MfaCandidate), SessionError) {
  case
    list.contains(nodes(store), node),
    limit > 0 && limit <= 200,
    string.length(query) <= 256
  {
    False, _, _ -> Error(InvalidSessionRequest("target_not_owned"))
    _, False, _ -> Error(InvalidSessionRequest("invalid_mfa_search_limit"))
    _, _, False -> Error(InvalidSessionRequest("mfa_search_query_too_long"))
    True, True, True ->
      case search_raw(store, node, query, limit) {
        Ok(candidates) -> Ok(candidates)
        Error("session_closed") -> Error(SessionClosed)
        Error(reason) -> Error(CaptureFailed(reason))
      }
  }
}

pub fn cancel(store: Store) -> Result(Nil, SessionError) {
  cancel_raw(store) |> map_control_result
}

pub fn live_snapshot_at(
  store: Store,
  node: String,
  limit: Int,
  now_ms now_ms: Int,
  ttl_ms ttl_ms: Int,
) -> Result(LiveSnapshot, SessionError) {
  case
    list.contains(nodes(store), node),
    limit > 0 && limit <= 1000,
    now_ms >= 0,
    ttl_ms > 0 && ttl_ms <= 60_000
  {
    False, _, _, _ -> Error(InvalidSessionRequest("target_not_owned"))
    _, False, _, _ -> Error(InvalidSessionRequest("invalid_live_sample_limit"))
    _, _, False, _ -> Error(InvalidSessionRequest("invalid_live_sample_time"))
    _, _, _, False -> Error(InvalidSessionRequest("invalid_live_sample_ttl"))
    True, True, True, True ->
      case live_snapshot_raw(store, node, limit, now_ms, ttl_ms) {
        Ok(snapshot) -> Ok(snapshot)
        Error("session_closed") -> Error(SessionClosed)
        Error(reason) -> Error(CaptureFailed(reason))
      }
  }
}

pub fn close(store: Store) -> Nil {
  close_raw(store)
}

fn capture_nodes(
  nodes: List(String),
  cookie: String,
  spec: ArmSpec,
) -> Result(capture.CaptureResult, String) {
  capture.execute(
    types.CaptureSpec(
      nodes: nodes,
      trigger: spec.trigger,
      where_aql: spec.where_aql,
      privacy: types.Metadata,
      budget: types.TraceBudget(
        max_events: spec.budget.max_events,
        max_bytes: spec.budget.max_bytes,
        max_duration_ms: spec.capture_window_ms,
        drain_timeout_ms: spec.drain_timeout_ms,
        max_agent_mailbox: spec.budget.max_agent_mailbox,
        max_roots: spec.max_roots,
      ),
      preset: spec.preset,
    ),
    cookie,
  )
}

fn valid_spec(spec: ArmSpec) -> Result(Nil, String) {
  case
    spec.capture_window_ms > 0 && spec.capture_window_ms <= 300_000,
    spec.drain_timeout_ms >= 1000 && spec.drain_timeout_ms <= 60_000,
    spec.budget.max_events > 0,
    spec.budget.max_bytes > 0,
    spec.budget.max_agent_mailbox > 0,
    spec.max_roots > 0 && spec.max_roots <= 1000
  {
    False, _, _, _, _, _ -> Error("invalid_capture_window")
    _, False, _, _, _, _ -> Error("invalid_drain_timeout")
    _, _, False, _, _, _ -> Error("invalid_event_budget")
    _, _, _, False, _, _ -> Error("invalid_byte_budget")
    _, _, _, _, False, _ -> Error("invalid_mailbox_budget")
    _, _, _, _, _, False -> Error("invalid_root_budget")
    True, True, True, True, True, True -> Ok(Nil)
  }
}

fn map_control_result(
  result: Result(Nil, String),
) -> Result(Nil, SessionError) {
  case result {
    Ok(Nil) -> Ok(Nil)
    Error("capture_already_running") -> Error(CaptureAlreadyRunning)
    Error("capture_not_ready") -> Error(CaptureNotReady)
    Error("session_closed") -> Error(SessionClosed)
    Error(reason) -> Error(CaptureFailed(reason))
  }
}

@external(erlang, "beamtrace_capture_session_ffi", "start")
fn start(
  nodes: List(String),
  backend: Backend,
  search_backend: SearchBackend,
  live_backend: LiveBackend,
) -> Store

@external(erlang, "beamtrace_capture_session_ffi", "live_snapshot")
fn live_snapshot_raw(
  store: Store,
  node: String,
  limit: Int,
  now_ms: Int,
  ttl_ms: Int,
) -> Result(LiveSnapshot, String)

@external(erlang, "beamtrace_capture_session_ffi", "arm")
fn arm_raw(store: Store, spec: ArmSpec) -> Result(Nil, String)

@external(erlang, "beamtrace_capture_session_ffi", "status")
fn status_raw(store: Store) -> Status

@external(erlang, "beamtrace_capture_session_ffi", "await_result")
fn await_raw(
  store: Store,
  timeout_ms: Int,
) -> Result(capture.CaptureResult, String)

@external(erlang, "beamtrace_capture_session_ffi", "result")
fn result_raw(store: Store) -> Result(capture.CaptureResult, String)

@external(erlang, "beamtrace_capture_session_ffi", "nodes")
fn nodes_raw(store: Store) -> List(String)

@external(erlang, "beamtrace_capture_session_ffi", "search_mfas")
fn search_raw(
  store: Store,
  node: String,
  query: String,
  limit: Int,
) -> Result(List(capture.MfaCandidate), String)

@external(erlang, "beamtrace_capture_session_ffi", "cancel")
fn cancel_raw(store: Store) -> Result(Nil, String)

@external(erlang, "beamtrace_capture_session_ffi", "close")
fn close_raw(store: Store) -> Nil
