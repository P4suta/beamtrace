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
  persist_classified_with(
    store,
    backend,
    "legacy-" <> relay_id,
    relay_id,
    sequence,
    mode,
    privacy,
    payload,
    received_at_ms,
    event_count: event_count,
    trace_session: False,
  )
}

pub fn persist_session_events_classified_with(
  store: team_store.Store,
  backend: blob_store.Backend,
  session_id: String,
  relay_id: String,
  sequence: Int,
  mode: Mode,
  privacy: relay_inbox.Privacy,
  payload: String,
  received_at_ms: Int,
  event_count event_count: Int,
) -> Result(team_store.RelayFrameIndex, String) {
  persist_classified_with(
    store,
    backend,
    session_id,
    relay_id,
    sequence,
    mode,
    privacy,
    payload,
    received_at_ms,
    event_count: event_count,
    trace_session: True,
  )
}

fn persist_classified_with(
  store: team_store.Store,
  backend: blob_store.Backend,
  session_id: String,
  relay_id: String,
  sequence: Int,
  mode: Mode,
  privacy: relay_inbox.Privacy,
  payload: String,
  received_at_ms: Int,
  event_count event_count: Int,
  trace_session trace_session: Bool,
) -> Result(team_store.RelayFrameIndex, String) {
  case valid_input(relay_id, sequence, event_count, received_at_ms) {
    False -> Error("invalid_relay_frame")
    True -> {
      let prefix = case trace_session {
        True -> "sessions/" <> session_id <> "/events/"
        False -> "relays/" <> relay_id <> "/frames/"
      }
      let key = prefix <> int.to_string(sequence) <> ".json"
      case blob_store.put_with(backend, key, payload) {
        Error(error) -> Error(error)
        Ok(blob) -> {
          let frame =
            team_store.RelayFrameIndex(
              session_id: session_id,
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
          let indexed = case trace_session {
            True -> team_store.put_trace_frame(store, frame)
            False ->
              team_store.put_relay_frame(store, frame)
              |> map_index_result(frame)
          }
          case indexed {
            Ok(saved) -> Ok(saved)
            Error(error) -> {
              // A same-content retry may have returned an already indexed
              // immutable object. Only roll back an object created by this
              // attempt; deleting a pre-existing one would corrupt the
              // durable frame that owns it.
              let _ = case blob.created {
                True -> blob_store.delete_with(backend, blob.key)
                False -> Ok(Nil)
              }
              Error(error)
            }
          }
        }
      }
    }
  }
}

fn map_index_result(
  result: Result(Nil, String),
  frame: team_store.RelayFrameIndex,
) -> Result(team_store.RelayFrameIndex, String) {
  case result {
    Ok(Nil) -> Ok(frame)
    Error(error) -> Error(error)
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

pub fn prune_sessions_before_with(
  store: team_store.Store,
  backend: blob_store.Backend,
  metadata_cutoff_ms metadata_cutoff_ms: Int,
  raw_cutoff_ms raw_cutoff_ms: Int,
  limit limit: Int,
) -> Result(PruneResult, String) {
  case limit > 0 && limit <= 1000 {
    False -> Error("invalid_retention_window")
    True ->
      drain_retention_queue(
        store,
        backend,
        metadata_cutoff_ms,
        raw_cutoff_ms,
        limit,
      )
  }
}

fn drain_retention_queue(
  store: team_store.Store,
  backend: blob_store.Backend,
  metadata_cutoff_ms: Int,
  raw_cutoff_ms: Int,
  limit: Int,
) -> Result(PruneResult, String) {
  case team_store.retention_blob_deletions(store, limit: limit + 1) {
    Error(error) -> Error(error)
    Ok(queued) -> {
      let selected = list.take(queued, limit)
      case delete_retention_blobs(store, backend, selected, 0, 0) {
        Error(error) -> Error(error)
        Ok(#(deleted_frames, deleted_bytes)) ->
          case list.length(queued) > limit {
            True -> Ok(PruneResult(deleted_frames, deleted_bytes, True))
            False ->
              prune_expired_trace_sessions(
                store,
                backend,
                metadata_cutoff_ms,
                raw_cutoff_ms,
                limit,
                deleted_frames,
                deleted_bytes,
              )
          }
      }
    }
  }
}

fn prune_expired_trace_sessions(
  store: team_store.Store,
  backend: blob_store.Backend,
  metadata_cutoff_ms: Int,
  raw_cutoff_ms: Int,
  limit: Int,
  deleted_frames: Int,
  deleted_bytes: Int,
) -> Result(PruneResult, String) {
  case
    team_store.expired_trace_sessions(
      store,
      metadata_cutoff_ms: metadata_cutoff_ms,
      raw_cutoff_ms: raw_cutoff_ms,
      limit: limit + 1,
    )
  {
    Error(error) -> Error(error)
    Ok(sessions) -> {
      let selected = list.take(sessions, limit)
      case
        prune_trace_sessions(
          store,
          backend,
          selected,
          deleted_frames,
          deleted_bytes,
        )
      {
        Error(error) -> Error(error)
        Ok(result) ->
          Ok(PruneResult(..result, more: list.length(sessions) > limit))
      }
    }
  }
}

fn prune_trace_sessions(
  store: team_store.Store,
  backend: blob_store.Backend,
  sessions: List(team_store.TraceSession),
  deleted_frames: Int,
  deleted_bytes: Int,
) -> Result(PruneResult, String) {
  case sessions {
    [] -> Ok(PruneResult(deleted_frames, deleted_bytes, False))
    [session, ..rest] ->
      case
        team_store.prepare_expired_trace_session_deletion(store, session.id)
      {
        Error("trace_retention_protected") ->
          prune_trace_sessions(
            store,
            backend,
            rest,
            deleted_frames,
            deleted_bytes,
          )
        Error(error) -> Error(error)
        Ok(blobs) ->
          case
            delete_retention_blobs(
              store,
              backend,
              blobs,
              deleted_frames,
              deleted_bytes,
            )
          {
            Error(error) -> Error(error)
            Ok(#(next_frames, next_bytes)) ->
              prune_trace_sessions(
                store,
                backend,
                rest,
                next_frames,
                next_bytes,
              )
          }
      }
  }
}

fn delete_retention_blobs(
  store: team_store.Store,
  backend: blob_store.Backend,
  blobs: List(team_store.RetentionBlob),
  deleted_frames: Int,
  deleted_bytes: Int,
) -> Result(#(Int, Int), String) {
  case blobs {
    [] -> Ok(#(deleted_frames, deleted_bytes))
    [blob, ..rest] ->
      case blob_store.delete_with(backend, blob.blob_key) {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case
            team_store.complete_retention_blob_deletion(store, blob.blob_key)
          {
            Error(error) -> Error(error)
            Ok(Nil) ->
              delete_retention_blobs(
                store,
                backend,
                rest,
                deleted_frames + 1,
                deleted_bytes + blob.bytes,
              )
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
