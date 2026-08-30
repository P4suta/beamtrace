// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/audit
import beamtrace_runtime/team_store_migration
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlight

pub opaque type Store {
  Store(connection: sqlight.Connection)
}

pub type SessionMetadata {
  SessionMetadata(
    id: String,
    project: String,
    environment: String,
    created_at_ms: Int,
    delivery_status: String,
    privacy: String,
    blob_key: String,
    event_count: Int,
  )
}

pub type SegmentIndex {
  SegmentIndex(
    session_id: String,
    ordinal: Int,
    first_event: Int,
    event_count: Int,
    blob_key: String,
    sha256: String,
  )
}

pub type RelayFrameIndex {
  RelayFrameIndex(
    session_id: String,
    relay_id: String,
    sequence: Int,
    received_at_ms: Int,
    mode: String,
    privacy: String,
    blob_key: String,
    event_count: Int,
    bytes: Int,
    sha256: String,
  )
}

pub type TraceSession {
  TraceSession(
    id: String,
    relay_id: String,
    project: String,
    environment: String,
    node: String,
    module_: String,
    function_: String,
    arity: Int,
    mode: String,
    privacy: String,
    started_at_ms: Int,
    received_at_ms: Int,
    ended_at_ms: Int,
    last_received_at_ms: Int,
    delivery_status: String,
    event_count: Int,
    legal_hold: Bool,
    active: Bool,
  )
}

/// A blob whose owning trace metadata has been atomically removed and whose
/// backend object still needs an idempotent deletion acknowledgement.
pub type RetentionBlob {
  RetentionBlob(blob_key: String, bytes: Int)
}

pub type AnnotationRow {
  AnnotationRow(
    id: String,
    event_id: String,
    text: String,
    author: String,
    created_at_ms: Int,
  )
}

pub type RelayIdentity {
  RelayIdentity(
    id: String,
    algorithm: String,
    public_key: BitArray,
    enrolled_at_ms: Int,
  )
}

pub type RawCaptureGrant {
  RawCaptureGrant(
    token_hash: String,
    relay_id: String,
    actor: String,
    created_at_ms: Int,
    expires_at_ms: Int,
    max_events: Int,
    used_events: Int,
    max_bytes: Int,
    used_bytes: Int,
    policy_hash: String,
    status: String,
  )
}

pub fn open(path: String) -> Result(Store, String) {
  case sqlight.open(path) {
    Error(error) -> Error(sql_error(error))
    Ok(connection) ->
      case team_store_migration.apply(connection) {
        Ok(Nil) -> Ok(Store(connection))
        Error(error) -> {
          let _ = sqlight.close(connection)
          Error(error)
        }
      }
  }
}

pub fn close(store: Store) -> Result(Nil, String) {
  let Store(connection) = store
  sqlight.close(connection) |> map_sql_error
}

pub fn journal_mode(store: Store) -> Result(String, String) {
  let Store(connection) = store
  case
    sqlight.query(
      "PRAGMA journal_mode;",
      on: connection,
      with: [],
      expecting: journal_mode_decoder(),
    )
  {
    Ok([mode]) -> Ok(mode)
    Ok(_) -> Error("missing_journal_mode")
    Error(error) -> Error(sql_error(error))
  }
}

fn journal_mode_decoder() -> decode.Decoder(String) {
  use mode <- decode.field(0, decode.string)
  decode.success(mode)
}

pub fn put_session(
  store: Store,
  metadata: SessionMetadata,
) -> Result(Nil, String) {
  case valid_session(metadata) {
    False -> Error("invalid_session_metadata")
    True -> {
      let Store(connection) = store
      execute(
        connection,
        "INSERT INTO sessions (
          id, project, environment, created_at_ms, completeness,
          privacy, blob_key, event_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          project = excluded.project,
          environment = excluded.environment,
          created_at_ms = excluded.created_at_ms,
          completeness = excluded.completeness,
          privacy = excluded.privacy,
          blob_key = excluded.blob_key,
          event_count = excluded.event_count;",
        [
          sqlight.text(metadata.id),
          sqlight.text(metadata.project),
          sqlight.text(metadata.environment),
          sqlight.int(metadata.created_at_ms),
          sqlight.text(metadata.delivery_status),
          sqlight.text(metadata.privacy),
          sqlight.text(metadata.blob_key),
          sqlight.int(metadata.event_count),
        ],
      )
    }
  }
}

pub fn get_session(
  store: Store,
  id: String,
) -> Result(Option(SessionMetadata), String) {
  case valid_text(id, 256) {
    False -> Error("invalid_session_id")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "SELECT id, project, environment, created_at_ms, completeness,
             privacy, blob_key, event_count
           FROM sessions WHERE id = ?;",
          on: connection,
          with: [sqlight.text(id)],
          expecting: session_decoder(),
        )
      {
        Ok([]) -> Ok(None)
        Ok([metadata]) -> Ok(Some(metadata))
        Ok(_) -> Error("duplicate_session")
        Error(error) -> Error(sql_error(error))
      }
    }
  }
}

pub fn begin_trace_session(
  store: Store,
  requested: TraceSession,
  max_active: Int,
) -> Result(TraceSession, String) {
  case valid_trace_session(requested), max_active > 0 && max_active <= 4096 {
    False, _ -> Error("invalid_trace_session")
    _, False -> Error("invalid_active_session_limit")
    True, True -> {
      let Store(connection) = store
      use Nil <- result_try(begin_transaction(connection))
      let result = case trace_session(store, requested.id) {
        Error(error) -> Error(error)
        Ok(Some(existing)) ->
          resume_trace_session(store, existing, requested, max_active)
        Ok(None) -> insert_trace_session(store, requested, max_active)
      }
      case result {
        Error(error) -> rollback_error(connection, error)
        Ok(_) ->
          case commit_transaction(connection) {
            Error(error) -> rollback_error(connection, error)
            Ok(Nil) -> trace_session_required(store, requested.id)
          }
      }
    }
  }
}

fn insert_trace_session(
  store: Store,
  requested: TraceSession,
  max_active: Int,
) -> Result(TraceSession, String) {
  case
    active_session_count(store),
    active_session_for_relay(store, requested.relay_id)
  {
    Error(error), _ | _, Error(error) -> Error(error)
    Ok(count), _ if count >= max_active -> Error("active_session_limit")
    _, Ok(Some(_)) -> Error("relay_session_active")
    Ok(_), Ok(None) -> {
      let Store(connection) = store
      let inserted =
        execute(
          connection,
          "INSERT INTO sessions (
           id, project, environment, created_at_ms, completeness,
           privacy, blob_key, event_count
         ) VALUES (?, ?, ?, ?, 'active', ?, ?, 0);",
          [
            sqlight.text(requested.id),
            sqlight.text(requested.project),
            sqlight.text(requested.environment),
            sqlight.int(requested.received_at_ms),
            sqlight.text(requested.privacy),
            sqlight.text("sessions/" <> requested.id <> "/manifest.json"),
          ],
        )
      case inserted {
        Error(error) -> Error(error)
        Ok(Nil) -> {
          let detailed =
            execute(
              connection,
              "INSERT INTO relay_session_details (
               session_id, relay_id, node, module, function, arity, mode,
               started_at_ms, received_at_ms, ended_at_ms,
               last_received_at_ms, legal_hold, active
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 0, 1);",
              [
                sqlight.text(requested.id),
                sqlight.text(requested.relay_id),
                sqlight.text(requested.node),
                sqlight.text(requested.module_),
                sqlight.text(requested.function_),
                sqlight.int(requested.arity),
                sqlight.text(requested.mode),
                sqlight.int(requested.started_at_ms),
                sqlight.int(requested.received_at_ms),
                sqlight.int(requested.received_at_ms),
              ],
            )
          case detailed {
            Error(error) -> Error(error)
            Ok(Nil) -> Ok(requested)
          }
        }
      }
    }
  }
}

fn resume_trace_session(
  store: Store,
  existing: TraceSession,
  requested: TraceSession,
  max_active: Int,
) -> Result(TraceSession, String) {
  case immutable_session_matches(existing, requested), existing.ended_at_ms {
    False, _ -> Error("session_metadata_conflict")
    _, ended if ended > 0 -> Error("session_already_ended")
    True, 0 if existing.active -> Error("relay_session_active")
    True, 0 -> {
      case
        active_session_count(store),
        active_session_for_relay(store, existing.relay_id)
      {
        Error(error), _ | _, Error(error) -> Error(error)
        Ok(count), _ if count >= max_active -> Error("active_session_limit")
        Ok(_), Ok(Some(active)) if active.id != existing.id ->
          Error("relay_session_active")
        Ok(_), Ok(_) -> {
          let Store(connection) = store
          let base =
            execute(
              connection,
              "UPDATE sessions SET completeness = 'active' WHERE id = ?;",
              [sqlight.text(existing.id)],
            )
          case base {
            Error(error) -> Error(error)
            Ok(Nil) -> {
              let detail =
                execute(
                  connection,
                  "UPDATE relay_session_details
                 SET active = 1, last_received_at_ms = ?
                 WHERE session_id = ?;",
                  [
                    sqlight.int(requested.received_at_ms),
                    sqlight.text(existing.id),
                  ],
                )
              case detail {
                Error(error) -> Error(error)
                Ok(Nil) -> Ok(existing)
              }
            }
          }
        }
      }
    }
    True, _ -> Error("invalid_session_state")
  }
}

pub fn trace_session(
  store: Store,
  id: String,
) -> Result(Option(TraceSession), String) {
  case valid_text(id, 256) {
    False -> Error("invalid_session_id")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          trace_session_select() <> " WHERE sessions.id = ?;",
          on: connection,
          with: [sqlight.text(id)],
          expecting: trace_session_decoder(),
        )
      {
        Ok([]) -> Ok(None)
        Ok([session]) -> Ok(Some(session))
        Ok(_) -> Error("duplicate_session")
        Error(error) -> Error(sql_error(error))
      }
    }
  }
}

pub fn trace_sessions(
  store: Store,
  start start: Int,
  limit limit: Int,
) -> Result(List(TraceSession), String) {
  // One look-ahead row lets the HTTP API distinguish a full final page from a
  // page that really has a successor. The public API still caps pages at 100.
  case start >= 0 && limit > 0 && limit <= 101 {
    False -> Error("invalid_trace_window")
    True -> {
      let Store(connection) = store
      sqlight.query(
        trace_session_select()
          <> " ORDER BY relay_session_details.received_at_ms DESC,
                      sessions.id DESC LIMIT ? OFFSET ?;",
        on: connection,
        with: [sqlight.int(limit), sqlight.int(start)],
        expecting: trace_session_decoder(),
      )
      |> map_sql_error
    }
  }
}

pub fn finish_trace_session(
  store: Store,
  session_id: String,
  relay_id: String,
  delivery_status: String,
  ended_at_ms: Int,
  received_at_ms: Int,
) -> Result(TraceSession, String) {
  case
    trace_session(store, session_id),
    list.contains(["delivered", "partial", "failed"], delivery_status),
    ended_at_ms >= 0 && received_at_ms >= 0
  {
    Error(error), _, _ -> Error(error)
    _, False, _ | _, _, False -> Error("invalid_session_end")
    Ok(None), _, _ -> Error("unknown_session")
    Ok(Some(existing)), _, _
      if existing.relay_id != relay_id || !existing.active
    -> Error("session_not_active")
    Ok(Some(existing)), True, True -> {
      let Store(connection) = store
      use Nil <- result_try(begin_transaction(connection))
      let base =
        execute(
          connection,
          "UPDATE sessions SET completeness = ? WHERE id = ?;",
          [sqlight.text(delivery_status), sqlight.text(existing.id)],
        )
      case base {
        Error(error) -> rollback_error(connection, error)
        Ok(Nil) -> {
          let detail =
            execute(
              connection,
              "UPDATE relay_session_details
             SET ended_at_ms = ?, last_received_at_ms = ?, active = 0
             WHERE session_id = ?;",
              [
                sqlight.int(ended_at_ms),
                sqlight.int(received_at_ms),
                sqlight.text(existing.id),
              ],
            )
          case detail {
            Error(error) -> rollback_error(connection, error)
            Ok(Nil) ->
              case commit_transaction(connection) {
                Error(error) -> rollback_error(connection, error)
                Ok(Nil) -> trace_session_required(store, existing.id)
              }
          }
        }
      }
    }
  }
}

pub fn mark_trace_failed(
  store: Store,
  session_id: String,
  relay_id: String,
  received_at_ms: Int,
) -> Result(Nil, String) {
  case received_at_ms >= 0 && valid_text(session_id, 256) {
    False -> Error("invalid_session_disconnect")
    True -> {
      let Store(connection) = store
      sqlight.exec("BEGIN IMMEDIATE;", connection)
      |> map_sql_error
      |> result_try(fn(_) {
        execute(
          connection,
          "UPDATE sessions SET completeness = 'failed'
           WHERE id = ? AND completeness = 'active'
             AND EXISTS (
               SELECT 1 FROM relay_session_details
               WHERE session_id = ? AND relay_id = ? AND active = 1
             );",
          [
            sqlight.text(session_id),
            sqlight.text(session_id),
            sqlight.text(relay_id),
          ],
        )
      })
      |> result_try(fn(_) {
        execute(
          connection,
          "UPDATE relay_session_details
           SET active = 0, last_received_at_ms = ?
           WHERE session_id = ? AND relay_id = ? AND active = 1;",
          [
            sqlight.int(received_at_ms),
            sqlight.text(session_id),
            sqlight.text(relay_id),
          ],
        )
      })
      |> finish_transaction(connection)
    }
  }
}

pub fn set_trace_legal_hold(
  store: Store,
  session_id: String,
  enabled: Bool,
) -> Result(TraceSession, String) {
  case trace_session(store, session_id) {
    Error(error) -> Error(error)
    Ok(None) -> Error("unknown_session")
    Ok(Some(_)) -> {
      let Store(connection) = store
      case
        execute(
          connection,
          "UPDATE relay_session_details SET legal_hold = ?
         WHERE session_id = ?;",
          [
            sqlight.int(case enabled {
              True -> 1
              False -> 0
            }),
            sqlight.text(session_id),
          ],
        )
      {
        Error(error) -> Error(error)
        Ok(Nil) -> trace_session_required(store, session_id)
      }
    }
  }
}

/// Commit a legal-hold transition and the corresponding next audit-chain
/// entry together. The supplied log must be the exact one-entry extension of
/// the chain already stored in this database.
pub fn set_trace_legal_hold_audited(
  store: Store,
  session_id: String,
  enabled: Bool,
  next_log: audit.AuditLog,
) -> Result(TraceSession, String) {
  case final_audit_entry(next_log.entries), audit.verify(next_log) {
    Error(_), _ | _, Error(_) -> Error("invalid_audit_entry")
    Ok(entry), Ok(Nil) -> {
      let Store(connection) = store
      use Nil <- result_try(begin_transaction(connection))
      let result = case trace_session(store, session_id), audit_log(store) {
        Error(error), _ | _, Error(error) -> Error(error)
        Ok(None), _ -> Error("unknown_session")
        Ok(Some(existing)), Ok(current_log) ->
          case audit_log_extends(current_log, next_log, entry) {
            False -> Error("audit_log_conflict")
            True ->
              execute(
                connection,
                "UPDATE relay_session_details SET legal_hold = ?
                 WHERE session_id = ?;",
                [
                  sqlight.int(case enabled {
                    True -> 1
                    False -> 0
                  }),
                  sqlight.text(session_id),
                ],
              )
              |> result_try(fn(_) { put_audit_entry(store, entry) })
              |> result_try(fn(_) {
                Ok(TraceSession(..existing, legal_hold: enabled))
              })
          }
      }
      finish_value_transaction(result, connection)
    }
  }
}

fn final_audit_entry(
  entries: List(audit.AuditEntry),
) -> Result(audit.AuditEntry, Nil) {
  case entries {
    [] -> Error(Nil)
    [entry] -> Ok(entry)
    [_, ..rest] -> final_audit_entry(rest)
  }
}

fn audit_log_extends(
  current: audit.AuditLog,
  next: audit.AuditLog,
  entry: audit.AuditEntry,
) -> Bool {
  entry.sequence == list.length(current.entries) + 1
  && entry.previous_hash == current.head_hash
  && list.length(next.entries) == list.length(current.entries) + 1
}

pub fn expired_trace_sessions(
  store: Store,
  metadata_cutoff_ms metadata_cutoff_ms: Int,
  raw_cutoff_ms raw_cutoff_ms: Int,
  limit limit: Int,
) -> Result(List(TraceSession), String) {
  case
    metadata_cutoff_ms >= 0,
    raw_cutoff_ms >= metadata_cutoff_ms,
    limit > 0 && limit <= 1001
  {
    False, _, _ | _, False, _ | _, _, False -> Error("invalid_retention_window")
    True, True, True -> {
      let Store(connection) = store
      sqlight.query(
        trace_session_select() <> " WHERE relay_session_details.active = 0
                    AND relay_session_details.legal_hold = 0
                    AND (
                      (sessions.privacy = 'metadata'
                       AND relay_session_details.received_at_ms < ?)
                      OR
                      (sessions.privacy IN ('raw', 'unknown')
                       AND relay_session_details.received_at_ms < ?)
                    )
                ORDER BY relay_session_details.received_at_ms ASC,
                         sessions.id ASC LIMIT ?;",
        on: connection,
        with: [
          sqlight.int(metadata_cutoff_ms),
          sqlight.int(raw_cutoff_ms),
          sqlight.int(limit),
        ],
        expecting: trace_session_decoder(),
      )
      |> map_sql_error
    }
  }
}

pub fn retention_trace_frames(
  store: Store,
  session_id: String,
  start start: Int,
  limit limit: Int,
) -> Result(List(RelayFrameIndex), String) {
  case valid_text(session_id, 256) && start >= 0 && limit > 0 && limit <= 1000 {
    False -> Error("invalid_retention_window")
    True -> {
      let Store(connection) = store
      sqlight.query(
        "SELECT session_id, relay_id, sequence, received_at_ms, mode,
                privacy, blob_key, event_count, bytes, sha256
         FROM relay_frames WHERE session_id = ?
         ORDER BY sequence ASC LIMIT ? OFFSET ?;",
        on: connection,
        with: [
          sqlight.text(session_id),
          sqlight.int(limit),
          sqlight.int(start),
        ],
        expecting: relay_frame_decoder(),
      )
      |> map_sql_error
    }
  }
}

/// Recheck legal hold and active state under a SQLite write transaction,
/// persist every blob deletion intent, and only then remove the trace indexes.
/// This makes a successful legal hold linearizable with retention and keeps
/// interrupted backend deletions retryable after restart.
pub fn prepare_expired_trace_session_deletion(
  store: Store,
  session_id: String,
) -> Result(List(RetentionBlob), String) {
  case valid_text(session_id, 256) {
    False -> Error("invalid_session_id")
    True -> {
      let Store(connection) = store
      use Nil <- result_try(begin_transaction(connection))
      case
        sqlight.query(
          "SELECT COUNT(*) FROM sessions
           JOIN relay_session_details
             ON relay_session_details.session_id = sessions.id
           WHERE sessions.id = ?
             AND relay_session_details.active = 0
             AND relay_session_details.legal_hold = 0;",
          on: connection,
          with: [sqlight.text(session_id)],
          expecting: count_decoder(),
        )
      {
        Error(error) -> rollback_error(connection, sql_error(error))
        Ok([0]) -> rollback_error(connection, "trace_retention_protected")
        Ok([1]) -> prepare_trace_blob_deletions(connection, session_id)
        Ok(_) -> rollback_error(connection, "invalid_trace_retention_state")
      }
    }
  }
}

fn prepare_trace_blob_deletions(
  connection: sqlight.Connection,
  session_id: String,
) -> Result(List(RetentionBlob), String) {
  case
    sqlight.query(
      "SELECT blob_key, bytes FROM relay_frames
       WHERE session_id = ? ORDER BY sequence ASC;",
      on: connection,
      with: [sqlight.text(session_id)],
      expecting: retention_blob_decoder(),
    )
  {
    Error(error) -> rollback_error(connection, sql_error(error))
    Ok(blobs) -> {
      let queued =
        execute(
          connection,
          "INSERT OR IGNORE INTO retention_blob_deletions (blob_key, bytes)
           SELECT blob_key, bytes FROM relay_frames WHERE session_id = ?;",
          [sqlight.text(session_id)],
        )
      case queued {
        Error(error) -> rollback_error(connection, error)
        Ok(Nil) -> delete_prepared_trace(connection, session_id, blobs)
      }
    }
  }
}

fn delete_prepared_trace(
  connection: sqlight.Connection,
  session_id: String,
  blobs: List(RetentionBlob),
) -> Result(List(RetentionBlob), String) {
  let frames =
    execute(connection, "DELETE FROM relay_frames WHERE session_id = ?;", [
      sqlight.text(session_id),
    ])
  case frames {
    Error(error) -> rollback_error(connection, error)
    Ok(Nil) -> {
      let session =
        execute(connection, "DELETE FROM sessions WHERE id = ?;", [
          sqlight.text(session_id),
        ])
      case session {
        Error(error) -> rollback_error(connection, error)
        Ok(Nil) ->
          case commit_transaction(connection) {
            Ok(Nil) -> Ok(blobs)
            Error(error) -> rollback_error(connection, error)
          }
      }
    }
  }
}

pub fn retention_blob_deletions(
  store: Store,
  limit limit: Int,
) -> Result(List(RetentionBlob), String) {
  case limit > 0 && limit <= 1001 {
    False -> Error("invalid_retention_window")
    True -> {
      let Store(connection) = store
      sqlight.query(
        "SELECT blob_key, bytes FROM retention_blob_deletions
         ORDER BY blob_key ASC LIMIT ?;",
        on: connection,
        with: [sqlight.int(limit)],
        expecting: retention_blob_decoder(),
      )
      |> map_sql_error
    }
  }
}

pub fn complete_retention_blob_deletion(
  store: Store,
  blob_key: String,
) -> Result(Nil, String) {
  case valid_blob_key(blob_key) {
    False -> Error("invalid_blob_key")
    True -> {
      let Store(connection) = store
      execute(
        connection,
        "DELETE FROM retention_blob_deletions WHERE blob_key = ?;",
        [sqlight.text(blob_key)],
      )
    }
  }
}

fn trace_session_required(
  store: Store,
  id: String,
) -> Result(TraceSession, String) {
  case trace_session(store, id) {
    Ok(Some(session)) -> Ok(session)
    Ok(None) -> Error("session_not_persisted")
    Error(error) -> Error(error)
  }
}

fn active_session_count(store: Store) -> Result(Int, String) {
  let Store(connection) = store
  case
    sqlight.query(
      "SELECT COUNT(*) FROM relay_session_details WHERE active = 1;",
      on: connection,
      with: [],
      expecting: count_decoder(),
    )
  {
    Ok([count]) -> Ok(count)
    Ok(_) -> Error("missing_active_session_count")
    Error(error) -> Error(sql_error(error))
  }
}

fn active_session_for_relay(
  store: Store,
  relay_id: String,
) -> Result(Option(TraceSession), String) {
  let Store(connection) = store
  case
    sqlight.query(
      trace_session_select() <> " WHERE relay_session_details.relay_id = ?
                    AND relay_session_details.active = 1;",
      on: connection,
      with: [sqlight.text(relay_id)],
      expecting: trace_session_decoder(),
    )
  {
    Ok([]) -> Ok(None)
    Ok([session]) -> Ok(Some(session))
    Ok(_) -> Error("multiple_active_relay_sessions")
    Error(error) -> Error(sql_error(error))
  }
}

fn immutable_session_matches(left: TraceSession, right: TraceSession) -> Bool {
  left.id == right.id
  && left.relay_id == right.relay_id
  && left.project == right.project
  && left.environment == right.environment
  && left.node == right.node
  && left.module_ == right.module_
  && left.function_ == right.function_
  && left.arity == right.arity
  && left.mode == right.mode
  && left.privacy == right.privacy
  && left.started_at_ms == right.started_at_ms
}

pub fn put_segment(store: Store, segment: SegmentIndex) -> Result(Nil, String) {
  case valid_segment(segment) {
    False -> Error("invalid_segment_index")
    True -> {
      let Store(connection) = store
      execute(
        connection,
        "INSERT INTO event_segments (
          session_id, ordinal, first_event, event_count, blob_key, sha256
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id, ordinal) DO UPDATE SET
          first_event = excluded.first_event,
          event_count = excluded.event_count,
          blob_key = excluded.blob_key,
          sha256 = excluded.sha256;",
        [
          sqlight.text(segment.session_id),
          sqlight.int(segment.ordinal),
          sqlight.int(segment.first_event),
          sqlight.int(segment.event_count),
          sqlight.text(segment.blob_key),
          sqlight.text(segment.sha256),
        ],
      )
    }
  }
}

pub fn segments(
  store: Store,
  session_id: String,
) -> Result(List(SegmentIndex), String) {
  case valid_text(session_id, 256) {
    False -> Error("invalid_session_id")
    True -> {
      let Store(connection) = store
      sqlight.query(
        "SELECT session_id, ordinal, first_event, event_count, blob_key, sha256
         FROM event_segments
         WHERE session_id = ? ORDER BY ordinal ASC;",
        on: connection,
        with: [sqlight.text(session_id)],
        expecting: segment_decoder(),
      )
      |> map_sql_error
    }
  }
}

pub fn segments_in_window(
  store: Store,
  session_id: String,
  start start: Int,
  limit limit: Int,
) -> Result(List(SegmentIndex), String) {
  case valid_text(session_id, 256) && start >= 0 && limit > 0 && limit <= 200 {
    False -> Error("invalid_segment_window")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "SELECT session_id, ordinal, first_event, event_count, blob_key, sha256
           FROM event_segments
           WHERE session_id = ?
             AND first_event + event_count > ?
             AND first_event < ?
           ORDER BY ordinal ASC LIMIT ?;",
          on: connection,
          with: [
            sqlight.text(session_id),
            sqlight.int(start),
            sqlight.int(start + limit),
            sqlight.int(limit + 1),
          ],
          expecting: segment_decoder(),
        )
        |> map_sql_error
      {
        Error(error) -> Error(error)
        Ok(segments) ->
          case list.length(segments) <= limit {
            True -> Ok(segments)
            False -> Error("overlapping_segment_window")
          }
      }
    }
  }
}

pub fn put_relay_frame(
  store: Store,
  frame: RelayFrameIndex,
) -> Result(Nil, String) {
  case valid_relay_frame(frame) {
    False -> Error("invalid_relay_frame_index")
    True -> {
      let Store(connection) = store
      case
        execute(
          connection,
          "INSERT INTO relay_frames (
            session_id, relay_id, sequence, received_at_ms, mode, privacy,
            blob_key, event_count, bytes, sha256
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(session_id, sequence) DO NOTHING;",
          [
            sqlight.text(frame.session_id),
            sqlight.text(frame.relay_id),
            sqlight.int(frame.sequence),
            sqlight.int(frame.received_at_ms),
            sqlight.text(frame.mode),
            sqlight.text(frame.privacy),
            sqlight.text(frame.blob_key),
            sqlight.int(frame.event_count),
            sqlight.int(frame.bytes),
            sqlight.text(frame.sha256),
          ],
        )
      {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case session_frame(store, frame.session_id, frame.sequence) {
            Ok(Some(existing)) if existing == frame -> Ok(Nil)
            Ok(Some(_)) -> Error("relay_frame_conflict")
            Ok(None) -> Error("relay_frame_not_persisted")
            Error(error) -> Error(error)
          }
      }
    }
  }
}

pub fn put_trace_frame(
  store: Store,
  frame: RelayFrameIndex,
) -> Result(RelayFrameIndex, String) {
  case valid_relay_frame(frame) && frame.event_count > 0 {
    False -> Error("invalid_relay_frame_index")
    True ->
      case session_frame(store, frame.session_id, frame.sequence) {
        Error(error) -> Error(error)
        Ok(Some(existing)) ->
          case same_trace_frame(existing, frame) {
            True -> Ok(existing)
            False -> Error("relay_frame_conflict")
          }
        Ok(None) -> insert_trace_frame(store, frame)
      }
  }
}

fn same_trace_frame(left: RelayFrameIndex, right: RelayFrameIndex) -> Bool {
  left.session_id == right.session_id
  && left.relay_id == right.relay_id
  && left.sequence == right.sequence
  && left.mode == right.mode
  && left.privacy == right.privacy
  && left.blob_key == right.blob_key
  && left.event_count == right.event_count
  && left.bytes == right.bytes
  && left.sha256 == right.sha256
}

fn insert_trace_frame(
  store: Store,
  frame: RelayFrameIndex,
) -> Result(RelayFrameIndex, String) {
  case trace_session(store, frame.session_id) {
    Error(error) -> Error(error)
    Ok(None) -> Error("unknown_session")
    Ok(Some(session)) ->
      case
        session.active,
        session.relay_id == frame.relay_id,
        session.mode == frame.mode,
        session.privacy == frame.privacy
      {
        False, _, _, _ -> Error("session_not_active")
        _, False, _, _ -> Error("session_relay_mismatch")
        _, _, False, _ -> Error("session_mode_mismatch")
        _, _, _, False -> Error("session_privacy_mismatch")
        True, True, True, True -> {
          let Store(connection) = store
          use Nil <- result_try(begin_transaction(connection))
          let indexed =
            execute(
              connection,
              "INSERT INTO relay_frames (
               session_id, relay_id, sequence, received_at_ms, mode, privacy,
               blob_key, event_count, bytes, sha256
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
              [
                sqlight.text(frame.session_id),
                sqlight.text(frame.relay_id),
                sqlight.int(frame.sequence),
                sqlight.int(frame.received_at_ms),
                sqlight.text(frame.mode),
                sqlight.text(frame.privacy),
                sqlight.text(frame.blob_key),
                sqlight.int(frame.event_count),
                sqlight.int(frame.bytes),
                sqlight.text(frame.sha256),
              ],
            )
          case indexed {
            Error(error) -> rollback_error(connection, error)
            Ok(Nil) -> {
              let segment =
                execute(
                  connection,
                  "INSERT INTO event_segments (
                   session_id, ordinal, first_event, event_count,
                   blob_key, sha256
                 ) VALUES (?, ?, ?, ?, ?, ?);",
                  [
                    sqlight.text(frame.session_id),
                    sqlight.int(frame.sequence),
                    sqlight.int(session.event_count),
                    sqlight.int(frame.event_count),
                    sqlight.text(frame.blob_key),
                    sqlight.text(frame.sha256),
                  ],
                )
              case segment {
                Error(error) -> rollback_error(connection, error)
                Ok(Nil) -> {
                  let counted =
                    execute(
                      connection,
                      "UPDATE sessions
                     SET event_count = event_count + ? WHERE id = ?;",
                      [
                        sqlight.int(frame.event_count),
                        sqlight.text(frame.session_id),
                      ],
                    )
                  case counted {
                    Error(error) -> rollback_error(connection, error)
                    Ok(Nil) -> {
                      let touched =
                        execute(
                          connection,
                          "UPDATE relay_session_details
                         SET last_received_at_ms = ? WHERE session_id = ?;",
                          [
                            sqlight.int(frame.received_at_ms),
                            sqlight.text(frame.session_id),
                          ],
                        )
                      case touched {
                        Error(error) -> rollback_error(connection, error)
                        Ok(Nil) ->
                          case commit_transaction(connection) {
                            Error(error) -> rollback_error(connection, error)
                            Ok(Nil) -> Ok(frame)
                          }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
  }
}

pub fn trace_frames(
  store: Store,
  session_id: String,
  start start: Int,
  limit limit: Int,
) -> Result(List(RelayFrameIndex), String) {
  case valid_text(session_id, 256) && start >= 0 && limit > 0 && limit <= 200 {
    False -> Error("invalid_trace_event_window")
    True -> {
      let Store(connection) = store
      sqlight.query(
        "SELECT session_id, relay_id, sequence, received_at_ms, mode,
                privacy, blob_key, event_count, bytes, sha256
         FROM relay_frames WHERE session_id = ?
         ORDER BY sequence ASC LIMIT ? OFFSET ?;",
        on: connection,
        with: [
          sqlight.text(session_id),
          sqlight.int(limit),
          sqlight.int(start),
        ],
        expecting: relay_frame_decoder(),
      )
      |> map_sql_error
    }
  }
}

pub fn trace_usage(
  store: Store,
  session_id: String,
) -> Result(#(Int, Int), String) {
  case valid_text(session_id, 256) {
    False -> Error("invalid_session_id")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "SELECT COALESCE(SUM(event_count), 0), COALESCE(SUM(bytes), 0)
           FROM relay_frames WHERE session_id = ?;",
          on: connection,
          with: [sqlight.text(session_id)],
          expecting: usage_decoder(),
        )
      {
        Ok([usage]) -> Ok(usage)
        Ok(_) -> Error("missing_session_usage")
        Error(error) -> Error(sql_error(error))
      }
    }
  }
}

pub fn relay_frame(
  store: Store,
  relay_id: String,
  sequence: Int,
) -> Result(Option(RelayFrameIndex), String) {
  case valid_relay_id(relay_id) && sequence > 0 {
    False -> Error("invalid_relay_frame_key")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "SELECT session_id, relay_id, sequence, received_at_ms, mode,
                  privacy, blob_key, event_count, bytes, sha256
           FROM relay_frames WHERE relay_id = ? AND sequence = ?;",
          on: connection,
          with: [sqlight.text(relay_id), sqlight.int(sequence)],
          expecting: relay_frame_decoder(),
        )
      {
        Ok([]) -> Ok(None)
        Ok([frame]) -> Ok(Some(frame))
        Ok(_) -> Error("duplicate_relay_frame")
        Error(error) -> Error(sql_error(error))
      }
    }
  }
}

pub fn session_frame(
  store: Store,
  session_id: String,
  sequence: Int,
) -> Result(Option(RelayFrameIndex), String) {
  case valid_text(session_id, 256) && sequence > 0 {
    False -> Error("invalid_relay_frame_key")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "SELECT session_id, relay_id, sequence, received_at_ms, mode,
                  privacy, blob_key, event_count, bytes, sha256
           FROM relay_frames WHERE session_id = ? AND sequence = ?;",
          on: connection,
          with: [sqlight.text(session_id), sqlight.int(sequence)],
          expecting: relay_frame_decoder(),
        )
      {
        Ok([]) -> Ok(None)
        Ok([frame]) -> Ok(Some(frame))
        Ok(_) -> Error("duplicate_relay_frame")
        Error(error) -> Error(sql_error(error))
      }
    }
  }
}

pub fn relay_frames(
  store: Store,
  relay_id: String,
  start start: Int,
  limit limit: Int,
) -> Result(List(RelayFrameIndex), String) {
  case valid_relay_id(relay_id) && start >= 0 && limit > 0 && limit <= 1000 {
    False -> Error("invalid_relay_frame_window")
    True -> {
      let Store(connection) = store
      sqlight.query(
        "SELECT session_id, relay_id, sequence, received_at_ms, mode,
                privacy, blob_key, event_count, bytes, sha256
         FROM relay_frames
         WHERE relay_id = ?
         ORDER BY received_at_ms ASC, session_id ASC, sequence ASC
         LIMIT ? OFFSET ?;",
        on: connection,
        with: [sqlight.text(relay_id), sqlight.int(limit), sqlight.int(start)],
        expecting: relay_frame_decoder(),
      )
      |> map_sql_error
    }
  }
}

pub fn relay_frame_count(
  store: Store,
  relay_id: String,
) -> Result(Int, String) {
  case valid_relay_id(relay_id) {
    False -> Error("invalid_relay_id")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "SELECT COUNT(*) FROM relay_frames WHERE relay_id = ?;",
          on: connection,
          with: [sqlight.text(relay_id)],
          expecting: count_decoder(),
        )
      {
        Ok([count]) -> Ok(count)
        Ok(_) -> Error("missing_relay_frame_count")
        Error(error) -> Error(sql_error(error))
      }
    }
  }
}

pub fn relay_usage(
  store: Store,
  relay_id: String,
) -> Result(#(Int, Int), String) {
  case valid_relay_id(relay_id) {
    False -> Error("invalid_relay_id")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "SELECT COALESCE(SUM(event_count), 0), COALESCE(SUM(bytes), 0)
           FROM relay_frames WHERE relay_id = ?;",
          on: connection,
          with: [sqlight.text(relay_id)],
          expecting: usage_decoder(),
        )
      {
        Ok([usage]) -> Ok(usage)
        Ok(_) -> Error("missing_relay_usage")
        Error(error) -> Error(sql_error(error))
      }
    }
  }
}

pub fn relay_frames_before(
  store: Store,
  cutoff_ms cutoff_ms: Int,
  limit limit: Int,
) -> Result(List(RelayFrameIndex), String) {
  case cutoff_ms >= 0 && limit > 0 && limit <= 1001 {
    False -> Error("invalid_retention_window")
    True -> {
      let Store(connection) = store
      sqlight.query(
        "SELECT session_id, relay_id, sequence, received_at_ms, mode,
                privacy, blob_key, event_count, bytes, sha256
         FROM relay_frames
         WHERE received_at_ms < ?
         ORDER BY received_at_ms ASC, relay_id ASC, sequence ASC LIMIT ?;",
        on: connection,
        with: [sqlight.int(cutoff_ms), sqlight.int(limit)],
        expecting: relay_frame_decoder(),
      )
      |> map_sql_error
    }
  }
}

pub fn delete_relay_frame(
  store: Store,
  relay_id: String,
  sequence: Int,
) -> Result(Nil, String) {
  case valid_relay_id(relay_id) && sequence > 0 {
    False -> Error("invalid_relay_frame_key")
    True -> {
      let Store(connection) = store
      execute(
        connection,
        "DELETE FROM relay_frames WHERE relay_id = ? AND sequence = ?;",
        [sqlight.text(relay_id), sqlight.int(sequence)],
      )
    }
  }
}

pub fn append_annotation(
  store: Store,
  event_id: String,
  text: String,
  author: String,
  created_at_ms: Int,
) -> Result(AnnotationRow, String) {
  case
    valid_text(event_id, 256),
    valid_body(text, 16_384),
    valid_text(author, 1024),
    created_at_ms >= 0
  {
    True, True, True, True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "INSERT INTO annotations (event_id, text, author, created_at_ms)
           VALUES (?, ?, ?, ?)
           RETURNING sequence, event_id, text, author, created_at_ms;",
          on: connection,
          with: [
            sqlight.text(event_id),
            sqlight.text(text),
            sqlight.text(author),
            sqlight.int(created_at_ms),
          ],
          expecting: annotation_decoder(),
        )
      {
        Ok([annotation]) -> Ok(annotation)
        Ok(_) -> Error("annotation_not_persisted")
        Error(error) -> Error(sql_error(error))
      }
    }
    _, _, _, _ -> Error("invalid_annotation")
  }
}

pub fn annotations(store: Store) -> Result(List(AnnotationRow), String) {
  let Store(connection) = store
  sqlight.query(
    "SELECT sequence, event_id, text, author, created_at_ms
     FROM annotations ORDER BY sequence ASC;",
    on: connection,
    with: [],
    expecting: annotation_decoder(),
  )
  |> map_sql_error
}

pub fn put_audit_entry(
  store: Store,
  entry: audit.AuditEntry,
) -> Result(Nil, String) {
  case valid_audit_entry(entry) {
    False -> Error("invalid_audit_entry")
    True -> {
      let Store(connection) = store
      case
        execute(
          connection,
          "INSERT INTO audit_entries (
            sequence, timestamp_ms, actor, action, resource, outcome,
            previous_hash, hash
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(sequence) DO NOTHING;",
          [
            sqlight.int(entry.sequence),
            sqlight.int(entry.timestamp_ms),
            sqlight.text(entry.actor),
            sqlight.text(entry.action),
            sqlight.text(entry.resource),
            sqlight.text(entry.outcome),
            sqlight.text(entry.previous_hash),
            sqlight.text(entry.hash),
          ],
        )
      {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case audit_entry(store, entry.sequence) {
            Ok(Some(existing)) if existing == entry -> Ok(Nil)
            Ok(Some(_)) -> Error("audit_entry_conflict")
            Ok(None) -> Error("audit_entry_not_persisted")
            Error(error) -> Error(error)
          }
      }
    }
  }
}

pub fn audit_log(store: Store) -> Result(audit.AuditLog, String) {
  let Store(connection) = store
  case
    sqlight.query(
      "SELECT sequence, timestamp_ms, actor, action, resource, outcome,
              previous_hash, hash
       FROM audit_entries ORDER BY sequence ASC;",
      on: connection,
      with: [],
      expecting: audit_entry_decoder(),
    )
  {
    Error(error) -> Error(sql_error(error))
    Ok(entries) -> {
      let log = audit.AuditLog(entries, audit_head(entries))
      case audit.verify(log) {
        Ok(Nil) -> Ok(log)
        Error(_) -> Error("invalid_audit_chain")
      }
    }
  }
}

pub fn put_relay_identity(
  store: Store,
  identity: RelayIdentity,
) -> Result(Nil, String) {
  case valid_relay_identity(identity) {
    False -> Error("invalid_relay_identity")
    True -> {
      let Store(connection) = store
      case
        execute(
          connection,
          "INSERT INTO relay_identities (
            id, algorithm, public_key, enrolled_at_ms
          ) VALUES (?, ?, ?, ?)
          ON CONFLICT(id) DO NOTHING;",
          [
            sqlight.text(identity.id),
            sqlight.text(identity.algorithm),
            sqlight.blob(identity.public_key),
            sqlight.int(identity.enrolled_at_ms),
          ],
        )
      {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case relay_identity(store, identity.id) {
            Ok(Some(existing)) if existing == identity -> Ok(Nil)
            Ok(Some(_)) -> Error("relay_identity_conflict")
            Ok(None) -> Error("relay_identity_not_persisted")
            Error(error) -> Error(error)
          }
      }
    }
  }
}

pub fn relay_identities(store: Store) -> Result(List(RelayIdentity), String) {
  let Store(connection) = store
  sqlight.query(
    "SELECT id, algorithm, public_key, enrolled_at_ms
     FROM relay_identities ORDER BY id ASC;",
    on: connection,
    with: [],
    expecting: relay_identity_decoder(),
  )
  |> map_sql_error
}

pub fn relay_identity_exists(
  store: Store,
  relay_id: String,
) -> Result(Bool, String) {
  case relay_identity(store, relay_id) {
    Ok(Some(_)) -> Ok(True)
    Ok(None) -> Ok(False)
    Error(error) -> Error(error)
  }
}

pub fn put_raw_capture_grant(
  store: Store,
  grant: RawCaptureGrant,
) -> Result(Nil, String) {
  case valid_raw_capture_grant(grant) {
    False -> Error("invalid_raw_capture_grant")
    True -> {
      let Store(connection) = store
      execute(
        connection,
        "INSERT INTO raw_capture_grants (
          token_hash, relay_id, actor, created_at_ms, expires_at_ms,
          max_events, used_events, max_bytes, used_bytes, policy_hash, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(token_hash) DO NOTHING;",
        [
          sqlight.text(grant.token_hash),
          sqlight.text(grant.relay_id),
          sqlight.text(grant.actor),
          sqlight.int(grant.created_at_ms),
          sqlight.int(grant.expires_at_ms),
          sqlight.int(grant.max_events),
          sqlight.int(grant.used_events),
          sqlight.int(grant.max_bytes),
          sqlight.int(grant.used_bytes),
          sqlight.text(grant.policy_hash),
          sqlight.text(grant.status),
        ],
      )
    }
  }
}

pub fn raw_capture_grant(
  store: Store,
  token_hash: String,
) -> Result(Option(RawCaptureGrant), String) {
  case valid_sha256(token_hash) {
    False -> Error("invalid_raw_capture_grant_hash")
    True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "SELECT token_hash, relay_id, actor, created_at_ms, expires_at_ms,
                  max_events, used_events, max_bytes, used_bytes,
                  policy_hash, status
           FROM raw_capture_grants WHERE token_hash = ?;",
          on: connection,
          with: [sqlight.text(token_hash)],
          expecting: raw_capture_grant_decoder(),
        )
      {
        Ok([]) -> Ok(None)
        Ok([grant]) -> Ok(Some(grant))
        Ok(_) -> Error("duplicate_raw_capture_grant")
        Error(error) -> Error(sql_error(error))
      }
    }
  }
}

/// Atomically reserve a raw grant's remaining event and byte budget. The
/// generic denial deliberately does not reveal whether a token exists,
/// expired, targets another relay, or exhausted its budget.
pub fn reserve_raw_capture_grant(
  store: Store,
  token_hash: String,
  relay_id: String,
  policy_hash: String,
  events events: Int,
  bytes bytes: Int,
  now_ms now_ms: Int,
) -> Result(Nil, String) {
  case
    valid_sha256(token_hash),
    valid_relay_id(relay_id),
    valid_sha256(policy_hash),
    events > 0,
    bytes > 0,
    now_ms >= 0
  {
    True, True, True, True, True, True -> {
      let Store(connection) = store
      case
        sqlight.query(
          "UPDATE raw_capture_grants
           SET used_events = used_events + ?,
               used_bytes = used_bytes + ?,
               status = CASE
                 WHEN used_events + ? >= max_events
                   OR used_bytes + ? >= max_bytes
                 THEN 'exhausted'
                 ELSE status
               END
           WHERE token_hash = ? AND relay_id = ? AND policy_hash = ?
             AND status = 'active' AND expires_at_ms > ?
             AND used_events + ? <= max_events
             AND used_bytes + ? <= max_bytes
           RETURNING token_hash;",
          on: connection,
          with: [
            sqlight.int(events),
            sqlight.int(bytes),
            sqlight.int(events),
            sqlight.int(bytes),
            sqlight.text(token_hash),
            sqlight.text(relay_id),
            sqlight.text(policy_hash),
            sqlight.int(now_ms),
            sqlight.int(events),
            sqlight.int(bytes),
          ],
          expecting: hash_decoder(),
        )
      {
        Ok([_]) -> Ok(Nil)
        Ok([]) -> Error("raw_capture_grant_denied")
        Ok(_) -> Error("raw_capture_grant_denied")
        Error(error) -> Error(sql_error(error))
      }
    }
    _, _, _, _, _, _ -> Error("raw_capture_grant_denied")
  }
}

fn relay_identity(
  store: Store,
  relay_id: String,
) -> Result(Option(RelayIdentity), String) {
  let Store(connection) = store
  case
    sqlight.query(
      "SELECT id, algorithm, public_key, enrolled_at_ms
       FROM relay_identities WHERE id = ?;",
      on: connection,
      with: [sqlight.text(relay_id)],
      expecting: relay_identity_decoder(),
    )
  {
    Ok([]) -> Ok(None)
    Ok([identity]) -> Ok(Some(identity))
    Ok(_) -> Error("duplicate_relay_identity")
    Error(error) -> Error(sql_error(error))
  }
}

fn audit_entry(
  store: Store,
  sequence: Int,
) -> Result(Option(audit.AuditEntry), String) {
  let Store(connection) = store
  case
    sqlight.query(
      "SELECT sequence, timestamp_ms, actor, action, resource, outcome,
              previous_hash, hash
       FROM audit_entries WHERE sequence = ?;",
      on: connection,
      with: [sqlight.int(sequence)],
      expecting: audit_entry_decoder(),
    )
  {
    Ok([]) -> Ok(None)
    Ok([entry]) -> Ok(Some(entry))
    Ok(_) -> Error("duplicate_audit_entry")
    Error(error) -> Error(sql_error(error))
  }
}

fn execute(
  connection: sqlight.Connection,
  statement: String,
  arguments: List(sqlight.Value),
) -> Result(Nil, String) {
  case
    sqlight.query(
      statement,
      on: connection,
      with: arguments,
      expecting: decode.success(Nil),
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(sql_error(error))
  }
}

fn session_decoder() -> decode.Decoder(SessionMetadata) {
  use id <- decode.field(0, decode.string)
  use project <- decode.field(1, decode.string)
  use environment <- decode.field(2, decode.string)
  use created_at_ms <- decode.field(3, decode.int)
  use delivery_status <- decode.field(4, decode.string)
  use privacy <- decode.field(5, decode.string)
  use blob_key <- decode.field(6, decode.string)
  use event_count <- decode.field(7, decode.int)
  decode.success(SessionMetadata(
    id,
    project,
    environment,
    created_at_ms,
    normalize_delivery_status(delivery_status),
    privacy,
    blob_key,
    event_count,
  ))
}

fn segment_decoder() -> decode.Decoder(SegmentIndex) {
  use session_id <- decode.field(0, decode.string)
  use ordinal <- decode.field(1, decode.int)
  use first_event <- decode.field(2, decode.int)
  use event_count <- decode.field(3, decode.int)
  use blob_key <- decode.field(4, decode.string)
  use sha256 <- decode.field(5, decode.string)
  decode.success(SegmentIndex(
    session_id,
    ordinal,
    first_event,
    event_count,
    blob_key,
    sha256,
  ))
}

fn relay_frame_decoder() -> decode.Decoder(RelayFrameIndex) {
  use session_id <- decode.field(0, decode.string)
  use relay_id <- decode.field(1, decode.string)
  use sequence <- decode.field(2, decode.int)
  use received_at_ms <- decode.field(3, decode.int)
  use mode <- decode.field(4, decode.string)
  use privacy <- decode.field(5, decode.string)
  use blob_key <- decode.field(6, decode.string)
  use event_count <- decode.field(7, decode.int)
  use bytes <- decode.field(8, decode.int)
  use sha256 <- decode.field(9, decode.string)
  decode.success(RelayFrameIndex(
    session_id,
    relay_id,
    sequence,
    received_at_ms,
    mode,
    privacy,
    blob_key,
    event_count,
    bytes,
    sha256,
  ))
}

fn retention_blob_decoder() -> decode.Decoder(RetentionBlob) {
  use blob_key <- decode.field(0, decode.string)
  use bytes <- decode.field(1, decode.int)
  decode.success(RetentionBlob(blob_key, bytes))
}

fn trace_session_decoder() -> decode.Decoder(TraceSession) {
  use id <- decode.field(0, decode.string)
  use relay_id <- decode.field(1, decode.string)
  use project <- decode.field(2, decode.string)
  use environment <- decode.field(3, decode.string)
  use node <- decode.field(4, decode.string)
  use module_ <- decode.field(5, decode.string)
  use function_ <- decode.field(6, decode.string)
  use arity <- decode.field(7, decode.int)
  use mode <- decode.field(8, decode.string)
  use privacy <- decode.field(9, decode.string)
  use started_at_ms <- decode.field(10, decode.int)
  use received_at_ms <- decode.field(11, decode.int)
  use ended_at_ms <- decode.field(12, decode.int)
  use last_received_at_ms <- decode.field(13, decode.int)
  use delivery_status <- decode.field(14, decode.string)
  use event_count <- decode.field(15, decode.int)
  use legal_hold <- decode.field(16, decode.int)
  use active <- decode.field(17, decode.int)
  decode.success(TraceSession(
    id,
    relay_id,
    project,
    environment,
    node,
    module_,
    function_,
    arity,
    mode,
    privacy,
    started_at_ms,
    received_at_ms,
    ended_at_ms,
    last_received_at_ms,
    normalize_delivery_status(delivery_status),
    event_count,
    legal_hold == 1,
    active == 1,
  ))
}

fn trace_session_select() -> String {
  "SELECT sessions.id, relay_session_details.relay_id,
          sessions.project, sessions.environment,
          relay_session_details.node, relay_session_details.module,
          relay_session_details.function, relay_session_details.arity,
          relay_session_details.mode, sessions.privacy,
          relay_session_details.started_at_ms,
          relay_session_details.received_at_ms,
          relay_session_details.ended_at_ms,
          relay_session_details.last_received_at_ms,
          sessions.completeness, sessions.event_count,
          relay_session_details.legal_hold,
          relay_session_details.active
   FROM sessions
   JOIN relay_session_details
     ON relay_session_details.session_id = sessions.id"
}

fn count_decoder() -> decode.Decoder(Int) {
  use count <- decode.field(0, decode.int)
  decode.success(count)
}

fn usage_decoder() -> decode.Decoder(#(Int, Int)) {
  use events <- decode.field(0, decode.int)
  use bytes <- decode.field(1, decode.int)
  decode.success(#(events, bytes))
}

fn annotation_decoder() -> decode.Decoder(AnnotationRow) {
  use sequence <- decode.field(0, decode.int)
  use event_id <- decode.field(1, decode.string)
  use text <- decode.field(2, decode.string)
  use author <- decode.field(3, decode.string)
  use created_at_ms <- decode.field(4, decode.int)
  decode.success(AnnotationRow(
    "annotation-" <> int.to_string(sequence),
    event_id,
    text,
    author,
    created_at_ms,
  ))
}

fn audit_entry_decoder() -> decode.Decoder(audit.AuditEntry) {
  use sequence <- decode.field(0, decode.int)
  use timestamp_ms <- decode.field(1, decode.int)
  use actor <- decode.field(2, decode.string)
  use action <- decode.field(3, decode.string)
  use resource <- decode.field(4, decode.string)
  use outcome <- decode.field(5, decode.string)
  use previous_hash <- decode.field(6, decode.string)
  use hash <- decode.field(7, decode.string)
  decode.success(audit.AuditEntry(
    sequence,
    timestamp_ms,
    actor,
    action,
    resource,
    outcome,
    previous_hash,
    hash,
  ))
}

fn relay_identity_decoder() -> decode.Decoder(RelayIdentity) {
  use id <- decode.field(0, decode.string)
  use algorithm <- decode.field(1, decode.string)
  use public_key <- decode.field(2, decode.bit_array)
  use enrolled_at_ms <- decode.field(3, decode.int)
  decode.success(RelayIdentity(id, algorithm, public_key, enrolled_at_ms))
}

fn raw_capture_grant_decoder() -> decode.Decoder(RawCaptureGrant) {
  use token_hash <- decode.field(0, decode.string)
  use relay_id <- decode.field(1, decode.string)
  use actor <- decode.field(2, decode.string)
  use created_at_ms <- decode.field(3, decode.int)
  use expires_at_ms <- decode.field(4, decode.int)
  use max_events <- decode.field(5, decode.int)
  use used_events <- decode.field(6, decode.int)
  use max_bytes <- decode.field(7, decode.int)
  use used_bytes <- decode.field(8, decode.int)
  use policy_hash <- decode.field(9, decode.string)
  use status <- decode.field(10, decode.string)
  decode.success(RawCaptureGrant(
    token_hash,
    relay_id,
    actor,
    created_at_ms,
    expires_at_ms,
    max_events,
    used_events,
    max_bytes,
    used_bytes,
    policy_hash,
    status,
  ))
}

fn hash_decoder() -> decode.Decoder(String) {
  use hash <- decode.field(0, decode.string)
  decode.success(hash)
}

fn valid_session(metadata: SessionMetadata) -> Bool {
  valid_text(metadata.id, 256)
  && valid_text(metadata.project, 256)
  && valid_text(metadata.environment, 256)
  && metadata.created_at_ms >= 0
  && valid_text(metadata.delivery_status, 1024)
  && list.contains(["metadata", "raw", "unknown"], metadata.privacy)
  && valid_blob_key(metadata.blob_key)
  && metadata.event_count >= 0
}

fn normalize_delivery_status(status: String) -> String {
  case status {
    "complete" -> "delivered"
    "truncated" -> "partial"
    "incomplete" -> "failed"
    other -> other
  }
}

fn valid_trace_session(session: TraceSession) -> Bool {
  valid_text(session.id, 256)
  && valid_relay_id(session.relay_id)
  && valid_text(session.project, 256)
  && valid_text(session.environment, 256)
  && valid_text(session.node, 255)
  && valid_text(session.module_, 255)
  && valid_text(session.function_, 255)
  && session.arity >= 0
  && session.arity <= 255
  && list.contains(["exact", "live"], session.mode)
  && list.contains(["metadata", "raw"], session.privacy)
  && session.started_at_ms >= 0
  && session.received_at_ms >= 0
  && session.ended_at_ms == 0
  && session.last_received_at_ms == session.received_at_ms
  && session.delivery_status == "active"
  && session.event_count == 0
  && !session.legal_hold
  && session.active
}

fn valid_segment(segment: SegmentIndex) -> Bool {
  valid_text(segment.session_id, 256)
  && segment.ordinal >= 0
  && segment.first_event >= 0
  && segment.event_count > 0
  && valid_blob_key(segment.blob_key)
  && case bit_array.base16_decode(segment.sha256) {
    Ok(bytes) -> bit_array.byte_size(bytes) == 32
    Error(_) -> False
  }
}

fn valid_relay_frame(frame: RelayFrameIndex) -> Bool {
  valid_text(frame.session_id, 256)
  && valid_relay_id(frame.relay_id)
  && frame.sequence > 0
  && frame.received_at_ms >= 0
  && list.contains(["exact", "live"], frame.mode)
  && list.contains(["metadata", "raw", "unknown"], frame.privacy)
  && valid_blob_key(frame.blob_key)
  && frame.event_count >= 0
  && frame.bytes > 0
  && frame.bytes <= 1_048_576
  && valid_sha256(frame.sha256)
}

fn valid_audit_entry(entry: audit.AuditEntry) -> Bool {
  entry.sequence > 0
  && entry.timestamp_ms >= 0
  && valid_body(entry.actor, 4096)
  && valid_body(entry.action, 4096)
  && valid_body(entry.resource, 4096)
  && valid_body(entry.outcome, 4096)
  && valid_sha256(entry.previous_hash)
  && valid_sha256(entry.hash)
}

fn valid_relay_identity(identity: RelayIdentity) -> Bool {
  valid_relay_id(identity.id)
  && identity.algorithm == "Ed25519"
  && bit_array.byte_size(identity.public_key) == 32
  && identity.enrolled_at_ms >= 0
}

fn valid_raw_capture_grant(grant: RawCaptureGrant) -> Bool {
  valid_sha256(grant.token_hash)
  && valid_relay_id(grant.relay_id)
  && valid_text(grant.actor, 1024)
  && grant.created_at_ms >= 0
  && grant.expires_at_ms > grant.created_at_ms
  && grant.max_events > 0
  && grant.used_events >= 0
  && grant.used_events <= grant.max_events
  && grant.max_bytes > 0
  && grant.used_bytes >= 0
  && grant.used_bytes <= grant.max_bytes
  && valid_sha256(grant.policy_hash)
  && list.contains(["active", "exhausted", "revoked"], grant.status)
}

fn audit_head(entries: List(audit.AuditEntry)) -> String {
  case entries {
    [] -> audit.genesis_hash
    [entry] -> entry.hash
    [_, ..rest] -> audit_head(rest)
  }
}

fn valid_relay_id(relay_id: String) -> Bool {
  case string.starts_with(relay_id, "relay-") {
    False -> False
    True -> {
      let suffix = string.drop_start(relay_id, 6)
      case bit_array.base16_decode(suffix) {
        Ok(bytes) ->
          bit_array.byte_size(bytes) == 12 && string.lowercase(suffix) == suffix
        Error(_) -> False
      }
    }
  }
}

fn valid_sha256(value: String) -> Bool {
  case bit_array.base16_decode(value) {
    Ok(bytes) ->
      bit_array.byte_size(bytes) == 32 && string.lowercase(value) == value
    Error(_) -> False
  }
}

fn valid_blob_key(key: String) -> Bool {
  valid_text(key, 1024)
  && !string.starts_with(key, "/")
  && !string.contains(key, "\\")
  && !string.contains(key, ":")
  && list.all(string.split(key, on: "/"), fn(segment) {
    segment != "" && segment != "." && segment != ".."
  })
}

fn valid_text(value: String, maximum_bytes: Int) -> Bool {
  let size = string.byte_size(value)
  size > 0
  && size <= maximum_bytes
  && !string.contains(value, "\u{0}")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn valid_body(value: String, maximum_bytes: Int) -> Bool {
  let size = string.byte_size(value)
  size > 0 && size <= maximum_bytes && !string.contains(value, "\u{0}")
}

fn map_sql_error(result: Result(a, sqlight.Error)) -> Result(a, String) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(sql_error(error))
  }
}

fn begin_transaction(connection: sqlight.Connection) -> Result(Nil, String) {
  sqlight.exec("BEGIN IMMEDIATE;", connection) |> map_sql_error
}

fn commit_transaction(connection: sqlight.Connection) -> Result(Nil, String) {
  sqlight.exec("COMMIT;", connection) |> map_sql_error
}

fn rollback_error(
  connection: sqlight.Connection,
  error: String,
) -> Result(a, String) {
  let _ = sqlight.exec("ROLLBACK;", connection)
  Error(error)
}

fn finish_transaction(
  result: Result(Nil, String),
  connection: sqlight.Connection,
) -> Result(Nil, String) {
  case result {
    Error(error) -> rollback_error(connection, error)
    Ok(Nil) ->
      case commit_transaction(connection) {
        Ok(Nil) -> Ok(Nil)
        Error(error) -> rollback_error(connection, error)
      }
  }
}

fn finish_value_transaction(
  result: Result(value, String),
  connection: sqlight.Connection,
) -> Result(value, String) {
  case result {
    Error(error) -> rollback_error(connection, error)
    Ok(value) ->
      case commit_transaction(connection) {
        Error(error) -> rollback_error(connection, error)
        Ok(Nil) -> Ok(value)
      }
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

fn sql_error(_error: sqlight.Error) -> String {
  "database_operation_failed"
}
