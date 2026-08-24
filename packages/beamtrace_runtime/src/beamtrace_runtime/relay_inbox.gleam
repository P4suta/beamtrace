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

/// Privacy is stored beside each payload so authorization can be decided
/// without decoding or returning the payload. Unknown is the conservative
/// classification for frames written before this field existed.
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

@external(erlang, "beamtrace_relay_inbox_ffi", "snapshot")
pub fn snapshot(store: Store, relay_id: String) -> List(Entry)

@external(erlang, "beamtrace_relay_inbox_ffi", "window")
pub fn window(
  store: Store,
  relay_id: String,
  start start: Int,
  limit limit: Int,
) -> Result(Window, String)

@external(erlang, "beamtrace_relay_inbox_ffi", "close")
pub fn close(store: Store) -> Nil
