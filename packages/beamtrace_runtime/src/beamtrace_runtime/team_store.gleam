// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/audit
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
    completeness: String,
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
    relay_id: String,
    sequence: Int,
    received_at_ms: Int,
    mode: String,
    blob_key: String,
    event_count: Int,
    bytes: Int,
    sha256: String,
  )
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

const schema = "
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY NOT NULL,
  project TEXT NOT NULL,
  environment TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  completeness TEXT NOT NULL,
  privacy TEXT NOT NULL,
  blob_key TEXT NOT NULL,
  event_count INTEGER NOT NULL CHECK (event_count >= 0)
);
CREATE TABLE IF NOT EXISTS event_segments (
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  first_event INTEGER NOT NULL CHECK (first_event >= 0),
  event_count INTEGER NOT NULL CHECK (event_count > 0),
  blob_key TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  PRIMARY KEY (session_id, ordinal)
);
CREATE INDEX IF NOT EXISTS event_segments_lookup
  ON event_segments(session_id, first_event);
CREATE TABLE IF NOT EXISTS relay_frames (
  relay_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence > 0),
  received_at_ms INTEGER NOT NULL CHECK (received_at_ms >= 0),
  mode TEXT NOT NULL CHECK (mode IN ('exact', 'live')),
  blob_key TEXT NOT NULL,
  event_count INTEGER NOT NULL DEFAULT 1 CHECK (event_count >= 0),
  bytes INTEGER NOT NULL CHECK (bytes > 0 AND bytes <= 1048576),
  sha256 TEXT NOT NULL,
  PRIMARY KEY (relay_id, sequence)
);
CREATE INDEX IF NOT EXISTS relay_frames_lookup
  ON relay_frames(relay_id, sequence);
CREATE TABLE IF NOT EXISTS annotations (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL,
  text TEXT NOT NULL,
  author TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0)
);
CREATE INDEX IF NOT EXISTS annotations_event_lookup
  ON annotations(event_id, sequence);
CREATE TABLE IF NOT EXISTS audit_entries (
  sequence INTEGER PRIMARY KEY NOT NULL CHECK (sequence > 0),
  timestamp_ms INTEGER NOT NULL CHECK (timestamp_ms >= 0),
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  resource TEXT NOT NULL,
  outcome TEXT NOT NULL,
  previous_hash TEXT NOT NULL,
  hash TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS relay_identities (
  id TEXT PRIMARY KEY NOT NULL,
  algorithm TEXT NOT NULL CHECK (algorithm = 'Ed25519'),
  public_key BLOB NOT NULL CHECK (length(public_key) = 32),
  enrolled_at_ms INTEGER NOT NULL CHECK (enrolled_at_ms >= 0)
);
"

pub fn open(path: String) -> Result(Store, String) {
  case sqlight.open(path) {
    Error(error) -> Error(sql_error(error))
    Ok(connection) ->
      case sqlight.exec(schema, connection) {
        Ok(Nil) ->
          case migrate(connection) {
            Ok(Nil) -> Ok(Store(connection))
            Error(error) -> {
              let _ = sqlight.close(connection)
              Error(error)
            }
          }
        Error(error) -> {
          let _ = sqlight.close(connection)
          Error(sql_error(error))
        }
      }
  }
}

fn migrate(connection: sqlight.Connection) -> Result(Nil, String) {
  case
    sqlight.query(
      "SELECT COUNT(*) FROM pragma_table_info('relay_frames')
       WHERE name = 'event_count';",
      on: connection,
      with: [],
      expecting: count_decoder(),
    )
  {
    Error(error) -> Error(sql_error(error))
    Ok([0]) ->
      case
        sqlight.exec(
          "ALTER TABLE relay_frames ADD COLUMN event_count INTEGER NOT NULL
           DEFAULT 1 CHECK (event_count >= 0);
           PRAGMA user_version = 5;",
          connection,
        )
      {
        Ok(Nil) -> Ok(Nil)
        Error(error) -> Error(sql_error(error))
      }
    Ok([1]) ->
      sqlight.exec("PRAGMA user_version = 5;", connection) |> map_sql_error
    Ok(_) -> Error("invalid_relay_schema")
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
          sqlight.text(metadata.completeness),
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
            relay_id, sequence, received_at_ms, mode, blob_key,
            event_count, bytes, sha256
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(relay_id, sequence) DO NOTHING;",
          [
            sqlight.text(frame.relay_id),
            sqlight.int(frame.sequence),
            sqlight.int(frame.received_at_ms),
            sqlight.text(frame.mode),
            sqlight.text(frame.blob_key),
            sqlight.int(frame.event_count),
            sqlight.int(frame.bytes),
            sqlight.text(frame.sha256),
          ],
        )
      {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case relay_frame(store, frame.relay_id, frame.sequence) {
            Ok(Some(existing)) if existing == frame -> Ok(Nil)
            Ok(Some(_)) -> Error("relay_frame_conflict")
            Ok(None) -> Error("relay_frame_not_persisted")
            Error(error) -> Error(error)
          }
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
          "SELECT relay_id, sequence, received_at_ms, mode, blob_key,
                  event_count, bytes, sha256
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
        "SELECT relay_id, sequence, received_at_ms, mode, blob_key,
                event_count, bytes, sha256
         FROM relay_frames
         WHERE relay_id = ? ORDER BY sequence ASC LIMIT ? OFFSET ?;",
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
        "SELECT relay_id, sequence, received_at_ms, mode, blob_key,
                event_count, bytes, sha256
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
  use completeness <- decode.field(4, decode.string)
  use privacy <- decode.field(5, decode.string)
  use blob_key <- decode.field(6, decode.string)
  use event_count <- decode.field(7, decode.int)
  decode.success(SessionMetadata(
    id,
    project,
    environment,
    created_at_ms,
    completeness,
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
  use relay_id <- decode.field(0, decode.string)
  use sequence <- decode.field(1, decode.int)
  use received_at_ms <- decode.field(2, decode.int)
  use mode <- decode.field(3, decode.string)
  use blob_key <- decode.field(4, decode.string)
  use event_count <- decode.field(5, decode.int)
  use bytes <- decode.field(6, decode.int)
  use sha256 <- decode.field(7, decode.string)
  decode.success(RelayFrameIndex(
    relay_id,
    sequence,
    received_at_ms,
    mode,
    blob_key,
    event_count,
    bytes,
    sha256,
  ))
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

fn valid_session(metadata: SessionMetadata) -> Bool {
  valid_text(metadata.id, 256)
  && valid_text(metadata.project, 256)
  && valid_text(metadata.environment, 256)
  && metadata.created_at_ms >= 0
  && valid_text(metadata.completeness, 1024)
  && list.contains(["metadata", "raw"], metadata.privacy)
  && valid_blob_key(metadata.blob_key)
  && metadata.event_count >= 0
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
  valid_relay_id(frame.relay_id)
  && frame.sequence > 0
  && frame.received_at_ms >= 0
  && list.contains(["exact", "live"], frame.mode)
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

fn sql_error(error: sqlight.Error) -> String {
  string.inspect(error)
}
