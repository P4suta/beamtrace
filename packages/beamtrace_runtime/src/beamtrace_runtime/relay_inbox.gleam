// SPDX-License-Identifier: Apache-2.0 OR MIT

pub type Store

pub type Mode {
  Exact
  Live
}

pub type AppendStatus {
  Accepted
  Truncated(reason: String)
}

/// Privacy is persisted beside every relay payload so authorization can be
/// decided without decoding or returning the payload itself. Unknown is the
/// conservative classification for data written before this field existed.
pub type Privacy {
  Metadata
  Raw
  Unknown
}

pub type Entry {
  Payload(sequence: Int, privacy: Privacy, payload: String, received_at_ms: Int)
  Gap(dropped_frames: Int, reason: String, received_at_ms: Int)
}

pub type Window {
  Window(entries: List(Entry), total: Int, start: Int, limit: Int)
}

@external(erlang, "beamtrace_relay_inbox_ffi", "new")
pub fn new(max_frames max_frames: Int, max_bytes max_bytes: Int) -> Store

@external(erlang, "beamtrace_relay_inbox_ffi", "append")
pub fn append(
  store: Store,
  relay_id: String,
  sequence: Int,
  mode: Mode,
  privacy: Privacy,
  payload: String,
  received_at_ms: Int,
) -> Result(AppendStatus, String)

/// Session-scoped v2 queues use the immutable 128-bit session id as their
/// independent budget key. The legacy relay-keyed API remains migration-only.
pub fn append_session(
  store: Store,
  session_id: String,
  sequence: Int,
  mode: Mode,
  privacy: Privacy,
  payload: String,
  received_at_ms: Int,
) -> Result(AppendStatus, String) {
  append(store, session_id, sequence, mode, privacy, payload, received_at_ms)
}

pub fn session_snapshot(store: Store, session_id: String) -> List(Entry) {
  snapshot(store, session_id)
}

pub fn session_window(
  store: Store,
  session_id: String,
  start start: Int,
  limit limit: Int,
) -> Result(Window, String) {
  window(store, session_id, start:, limit:)
}

@external(erlang, "beamtrace_relay_inbox_ffi", "snapshot")
pub fn snapshot(store: Store, relay_id: String) -> List(Entry)

@external(erlang, "beamtrace_relay_inbox_ffi", "window")
pub fn window(
  store: Store,
  relay_id: String,
  start start: Int,
  limit limit: Int,
) -> Result(Window, String)

/// Returns the selected payloads only after `authorize_raw` succeeds when the
/// page contains a raw or unknown frame. Metadata-only pages do not invoke the
/// callback.
@external(erlang, "beamtrace_relay_inbox_ffi", "authorized_window")
pub fn authorized_window(
  store: Store,
  relay_id: String,
  start start: Int,
  limit limit: Int,
  authorize_raw authorize_raw: fn() -> Bool,
) -> Result(Window, String)

@external(erlang, "beamtrace_relay_inbox_ffi", "close")
pub fn close(store: Store) -> Nil
