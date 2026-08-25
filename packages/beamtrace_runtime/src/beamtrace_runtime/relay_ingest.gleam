// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/raw_grant
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_payload
import beamtrace_runtime/team_store
import gleam/option.{None, Some}
import gleam/string

pub type Quota {
  Quota(max_events: Int, max_bytes: Int)
}

pub fn accept(
  metadata: team_store.Store,
  blob_root: String,
  inbox: relay_inbox.Store,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  payload: String,
  received_at_ms: Int,
) -> Result(relay_inbox.AppendStatus, String) {
  accept_with_quota(
    metadata,
    blob_root,
    inbox,
    relay_id,
    sequence,
    mode,
    payload,
    received_at_ms,
    Quota(max_events: 1_000_000, max_bytes: 1_073_741_824),
  )
}

pub fn accept_with_quota(
  metadata: team_store.Store,
  blob_root: String,
  inbox: relay_inbox.Store,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  payload: String,
  received_at_ms: Int,
  quota: Quota,
) -> Result(relay_inbox.AppendStatus, String) {
  accept_with_backend_quota(
    metadata,
    blob_store.filesystem(blob_root),
    inbox,
    relay_id,
    sequence,
    mode,
    payload,
    received_at_ms,
    quota,
  )
}

pub fn accept_with_backend_quota(
  metadata: team_store.Store,
  backend: blob_store.Backend,
  inbox: relay_inbox.Store,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  payload: String,
  received_at_ms: Int,
  quota: Quota,
) -> Result(relay_inbox.AppendStatus, String) {
  case relay_payload.decode_for_ingest(payload) {
    Error(error) -> Error(error)
    Ok(batch) ->
      accept_validated(
        metadata,
        backend,
        inbox,
        relay_id,
        sequence,
        mode,
        batch,
        received_at_ms,
        quota,
      )
  }
}

pub fn accept_session_with_backend_quota(
  metadata: team_store.Store,
  backend: blob_store.Backend,
  inbox: relay_inbox.Store,
  session_id: String,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  payload: String,
  received_at_ms: Int,
  quota: Quota,
) -> Result(relay_inbox.AppendStatus, String) {
  case relay_payload.decode_for_ingest(payload) {
    Error(error) -> Error(error)
    Ok(batch) ->
      accept_session_validated(
        metadata,
        backend,
        inbox,
        session_id,
        relay_id,
        sequence,
        mode,
        batch,
        received_at_ms,
        quota,
      )
  }
}

fn accept_session_validated(
  metadata: team_store.Store,
  backend: blob_store.Backend,
  inbox: relay_inbox.Store,
  session_id: String,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  batch: relay_payload.Batch,
  received_at_ms: Int,
  quota: Quota,
) -> Result(relay_inbox.AppendStatus, String) {
  case
    mode_matches(mode, batch.mode),
    quota.max_events > 0 && quota.max_bytes > 0,
    team_store.trace_session(metadata, session_id)
  {
    False, _, _ -> Error("invalid_payload")
    _, False, _ -> Error("invalid_relay_quota")
    _, _, Error(error) -> Error(error)
    _, _, Ok(None) -> Error("unknown_session")
    True, True, Ok(Some(session)) ->
      case
        session.active,
        session.relay_id == relay_id,
        session.mode == batch.mode,
        session.privacy == batch_privacy_name(batch),
        batch.event_count > 0
      {
        False, _, _, _, _ -> Error("session_not_active")
        _, False, _, _, _ -> Error("session_relay_mismatch")
        _, _, False, _, _ -> Error("session_mode_mismatch")
        _, _, _, False, _ -> Error("session_privacy_mismatch")
        _, _, _, _, False -> Error("empty_batch")
        True, True, True, True, True ->
          case team_store.session_frame(metadata, session_id, sequence) {
            Error(error) -> Error(error)
            Ok(Some(existing)) ->
              accept_replayed_session_frame(backend, relay_id, existing, batch)
            Ok(None) ->
              case team_store.trace_usage(metadata, session_id) {
                Error(error) -> Error(error)
                Ok(#(events, bytes)) ->
                  case
                    events + batch.event_count > quota.max_events,
                    bytes + string.byte_size(batch.canonical) > quota.max_bytes
                  {
                    True, _ -> Error("session_event_quota")
                    _, True -> Error("session_byte_quota")
                    False, False -> {
                      use Nil <- result_try(authorize_privacy(
                        metadata,
                        relay_id,
                        batch,
                        received_at_ms,
                      ))
                      persist_session_and_publish(
                        metadata,
                        backend,
                        inbox,
                        session_id,
                        relay_id,
                        sequence,
                        mode,
                        batch_privacy(batch),
                        batch.canonical,
                        batch.event_count,
                        received_at_ms,
                      )
                    }
                  }
              }
          }
      }
  }
}

fn accept_replayed_session_frame(
  backend: blob_store.Backend,
  relay_id: String,
  existing: team_store.RelayFrameIndex,
  batch: relay_payload.Batch,
) -> Result(relay_inbox.AppendStatus, String) {
  case
    existing.relay_id == relay_id,
    existing.mode == batch.mode,
    existing.privacy == batch_privacy_name(batch),
    existing.event_count == batch.event_count,
    relay_archive.read_payload_with(backend, existing)
  {
    False, _, _, _, _
    | _, False, _, _, _
    | _, _, False, _, _
    | _, _, _, False, _
    -> Error("relay_frame_conflict")
    True, True, True, True, Ok(payload) if payload == batch.canonical ->
      Ok(relay_inbox.Accepted)
    True, True, True, True, Ok(_) -> Error("relay_frame_conflict")
    True, True, True, True, Error(error) -> Error(error)
  }
}

fn accept_validated(
  metadata: team_store.Store,
  backend: blob_store.Backend,
  inbox: relay_inbox.Store,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  batch: relay_payload.Batch,
  received_at_ms: Int,
  quota: Quota,
) -> Result(relay_inbox.AppendStatus, String) {
  case
    mode_matches(mode, batch.mode),
    quota.max_events > 0 && quota.max_bytes > 0
  {
    False, _ -> Error("invalid_payload")
    _, False -> Error("invalid_relay_quota")
    True, True ->
      case team_store.relay_usage(metadata, relay_id) {
        Error(error) -> Error(error)
        Ok(usage) -> {
          let #(events, bytes) = usage
          case
            events + batch.event_count > quota.max_events,
            bytes + string.byte_size(batch.canonical) > quota.max_bytes
          {
            True, _ -> Error("relay_event_quota")
            _, True -> Error("relay_byte_quota")
            False, False -> {
              use Nil <- result_try(authorize_privacy(
                metadata,
                relay_id,
                batch,
                received_at_ms,
              ))
              persist_and_publish(
                metadata,
                backend,
                inbox,
                relay_id,
                sequence,
                mode,
                batch_privacy(batch),
                batch.canonical,
                batch.event_count,
                received_at_ms,
              )
            }
          }
        }
      }
  }
}

fn authorize_privacy(
  metadata: team_store.Store,
  relay_id: String,
  batch: relay_payload.Batch,
  now_ms: Int,
) -> Result(Nil, String) {
  case batch.privacy {
    relay_payload.MetadataBatch -> Ok(Nil)
    relay_payload.RawBatch(token, policy) ->
      raw_grant.reserve(
        metadata,
        token,
        relay_id,
        policy,
        events: batch.event_count,
        bytes: string.byte_size(batch.canonical),
        now_ms: now_ms,
      )
  }
}

fn mode_matches(mode: relay_inbox.Mode, encoded: String) -> Bool {
  case mode, encoded {
    relay_inbox.Exact, "exact" | relay_inbox.Live, "live" -> True
    _, _ -> False
  }
}

fn persist_and_publish(
  metadata: team_store.Store,
  backend: blob_store.Backend,
  inbox: relay_inbox.Store,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  privacy: relay_inbox.Privacy,
  payload: String,
  event_count: Int,
  received_at_ms: Int,
) -> Result(relay_inbox.AppendStatus, String) {
  let archive_mode = case mode {
    relay_inbox.Exact -> relay_archive.Exact
    relay_inbox.Live -> relay_archive.Live
  }
  case
    relay_archive.persist_events_classified_with(
      metadata,
      backend,
      relay_id,
      sequence,
      archive_mode,
      privacy,
      payload,
      received_at_ms,
      event_count: event_count,
    )
  {
    Error(error) -> Error(error)
    Ok(_) ->
      relay_inbox.append(
        inbox,
        relay_id,
        sequence,
        mode,
        privacy,
        payload,
        received_at_ms,
      )
  }
}

fn persist_session_and_publish(
  metadata: team_store.Store,
  backend: blob_store.Backend,
  inbox: relay_inbox.Store,
  session_id: String,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  privacy: relay_inbox.Privacy,
  payload: String,
  event_count: Int,
  received_at_ms: Int,
) -> Result(relay_inbox.AppendStatus, String) {
  let archive_mode = case mode {
    relay_inbox.Exact -> relay_archive.Exact
    relay_inbox.Live -> relay_archive.Live
  }
  case
    relay_archive.persist_session_events_classified_with(
      metadata,
      backend,
      session_id,
      relay_id,
      sequence,
      archive_mode,
      privacy,
      payload,
      received_at_ms,
      event_count: event_count,
    )
  {
    Error(error) -> Error(error)
    Ok(_) ->
      relay_inbox.append_session(
        inbox,
        session_id,
        sequence,
        mode,
        privacy,
        payload,
        received_at_ms,
      )
  }
}

fn batch_privacy(batch: relay_payload.Batch) -> relay_inbox.Privacy {
  case batch.privacy {
    relay_payload.MetadataBatch -> relay_inbox.Metadata
    relay_payload.RawBatch(_, _) -> relay_inbox.Raw
  }
}

fn batch_privacy_name(batch: relay_payload.Batch) -> String {
  case batch.privacy {
    relay_payload.MetadataBatch -> "metadata"
    relay_payload.RawBatch(_, _) -> "raw"
  }
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}
