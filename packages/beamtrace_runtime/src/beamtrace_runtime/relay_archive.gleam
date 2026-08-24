// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/team_store
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

pub type Mode {
  Exact
  Live
}

pub type PruneResult {
  PruneResult(deleted_frames: Int, deleted_bytes: Int, more: Bool)
}

pub fn persist(
  store: team_store.Store,
  blob_root: String,
  relay_id: String,
  sequence: Int,
  mode: Mode,
  payload: String,
  received_at_ms: Int,
) -> Result(team_store.RelayFrameIndex, String) {
  persist_with(
    store,
    blob_store.filesystem(blob_root),
    relay_id,
    sequence,
    mode,
    payload,
    received_at_ms,
  )
}

pub fn persist_with(
  store: team_store.Store,
  backend: blob_store.Backend,
  relay_id: String,
  sequence: Int,
  mode: Mode,
  payload: String,
  received_at_ms: Int,
) -> Result(team_store.RelayFrameIndex, String) {
  persist_events_with(
    store,
    backend,
    relay_id,
    sequence,
    mode,
    payload,
    received_at_ms,
    event_count: 1,
  )
}

pub fn persist_events(
  store: team_store.Store,
  blob_root: String,
  relay_id: String,
  sequence: Int,
  mode: Mode,
  payload: String,
  received_at_ms: Int,
  event_count event_count: Int,
) -> Result(team_store.RelayFrameIndex, String) {
  persist_events_with(
    store,
    blob_store.filesystem(blob_root),
    relay_id,
    sequence,
    mode,
    payload,
    received_at_ms,
    event_count: event_count,
  )
}

pub fn persist_events_with(
  store: team_store.Store,
  backend: blob_store.Backend,
  relay_id: String,
  sequence: Int,
  mode: Mode,
  payload: String,
  received_at_ms: Int,
  event_count event_count: Int,
) -> Result(team_store.RelayFrameIndex, String) {
  persist_events_classified_with(
    store,
    backend,
    relay_id,
    sequence,
    mode,
    relay_inbox.Unknown,
    payload,
    received_at_ms,
    event_count: event_count,
  )
}

pub fn persist_events_classified_with(
  store: team_store.Store,
  backend: blob_store.Backend,
  relay_id: String,
  sequence: Int,
  mode: Mode,
  privacy: relay_inbox.Privacy,
  payload: String,
  received_at_ms: Int,
  event_count event_count: Int,
) -> Result(team_store.RelayFrameIndex, String) {
  case valid_input(relay_id, sequence, event_count, received_at_ms) {
    False -> Error("invalid_relay_frame")
    True -> {
      let key =
        "relays/"
        <> relay_id
        <> "/frames/"
        <> int.to_string(sequence)
        <> ".json"
      case blob_store.put_with(backend, key, payload) {
        Error(error) -> Error(error)
        Ok(blob) -> {
          let frame =
            team_store.RelayFrameIndex(
              relay_id: relay_id,
              sequence: sequence,
              received_at_ms: received_at_ms,
              mode: mode_name(mode),
              privacy: privacy_name(privacy),
              blob_key: blob.key,
              event_count: event_count,
              bytes: blob.bytes,
              sha256: blob.sha256,
            )
          case team_store.put_relay_frame(store, frame) {
            Ok(Nil) -> Ok(frame)
            Error(error) -> Error(error)
          }
        }
      }
    }
  }
}

pub fn read_payload(
  blob_root: String,
  frame: team_store.RelayFrameIndex,
) -> Result(String, String) {
  read_payload_with(blob_store.filesystem(blob_root), frame)
}

pub fn read_payload_with(
  backend: blob_store.Backend,
  frame: team_store.RelayFrameIndex,
) -> Result(String, String) {
  blob_store.read_verified_with(
    backend,
    frame.blob_key,
    frame.sha256,
    frame.bytes,
  )
}

pub fn prune_before(
  store: team_store.Store,
  blob_root: String,
  cutoff_ms cutoff_ms: Int,
  limit limit: Int,
) -> Result(PruneResult, String) {
  prune_before_with(store, blob_store.filesystem(blob_root), cutoff_ms:, limit:)
}

pub fn prune_before_with(
  store: team_store.Store,
  backend: blob_store.Backend,
  cutoff_ms cutoff_ms: Int,
  limit limit: Int,
) -> Result(PruneResult, String) {
  case cutoff_ms >= 0 && limit > 0 && limit <= 1000 {
    False -> Error("invalid_retention_window")
    True ->
      case team_store.relay_frames_before(store, cutoff_ms:, limit: limit + 1) {
        Error(error) -> Error(error)
        Ok(frames) -> {
          let selected = list.take(frames, limit)
          case prune_frames(store, backend, selected, 0, 0) {
            Error(error) -> Error(error)
            Ok(result) ->
              Ok(PruneResult(..result, more: list.length(frames) > limit))
          }
        }
      }
  }
}

fn prune_frames(
  store: team_store.Store,
  backend: blob_store.Backend,
  frames: List(team_store.RelayFrameIndex),
  deleted_frames: Int,
  deleted_bytes: Int,
) -> Result(PruneResult, String) {
  case frames {
    [] -> Ok(PruneResult(deleted_frames, deleted_bytes, False))
    [frame, ..rest] ->
      case blob_store.delete_with(backend, frame.blob_key) {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case
            team_store.delete_relay_frame(store, frame.relay_id, frame.sequence)
          {
            Error(error) -> Error(error)
            Ok(Nil) ->
              prune_frames(
                store,
                backend,
                rest,
                deleted_frames + 1,
                deleted_bytes + frame.bytes,
              )
          }
      }
  }
}

fn mode_name(mode: Mode) -> String {
  case mode {
    Exact -> "exact"
    Live -> "live"
  }
}

fn privacy_name(privacy: relay_inbox.Privacy) -> String {
  case privacy {
    relay_inbox.Metadata -> "metadata"
    relay_inbox.Raw -> "raw"
    relay_inbox.Unknown -> "unknown"
  }
}

fn valid_input(
  relay_id: String,
  sequence: Int,
  event_count: Int,
  received_at_ms: Int,
) -> Bool {
  sequence > 0
  && event_count >= 0
  && received_at_ms >= 0
  && string.starts_with(relay_id, "relay-")
  && {
    let suffix = string.drop_start(relay_id, 6)
    case bit_array.base16_decode(suffix) {
      Ok(bytes) ->
        bit_array.byte_size(bytes) == 12 && string.lowercase(suffix) == suffix
      Error(_) -> False
    }
  }
}
