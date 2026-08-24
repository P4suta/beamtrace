// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/raw_grant
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_payload
import beamtrace_runtime/team_store
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

fn batch_privacy(batch: relay_payload.Batch) -> relay_inbox.Privacy {
  case batch.privacy {
    relay_payload.MetadataBatch -> relay_inbox.Metadata
    relay_payload.RawBatch(_, _) -> relay_inbox.Raw
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
