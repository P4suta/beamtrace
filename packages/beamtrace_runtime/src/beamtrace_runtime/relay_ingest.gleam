// SPDX-License-Identifier: Apache-2.0 OR MIT
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
  case relay_payload.decode(payload) {
    Error(error) -> Error(error)
    Ok(batch) ->
      accept_validated(
        metadata,
        blob_root,
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
  blob_root: String,
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
            False, False ->
              persist_and_publish(
                metadata,
                blob_root,
                inbox,
                relay_id,
                sequence,
                mode,
                batch.canonical,
                batch.event_count,
                received_at_ms,
              )
          }
        }
      }
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
  blob_root: String,
  inbox: relay_inbox.Store,
  relay_id: String,
  sequence: Int,
  mode: relay_inbox.Mode,
  payload: String,
  event_count: Int,
  received_at_ms: Int,
) -> Result(relay_inbox.AppendStatus, String) {
  let archive_mode = case mode {
    relay_inbox.Exact -> relay_archive.Exact
    relay_inbox.Live -> relay_archive.Live
  }
  case
    relay_archive.persist_events(
      metadata,
      blob_root,
      relay_id,
      sequence,
      archive_mode,
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
        payload,
        received_at_ms,
      )
  }
}
