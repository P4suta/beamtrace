// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/dynamic/decode
import gleam/string
import sqlight

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
CREATE TABLE IF NOT EXISTS relay_session_details (
  session_id TEXT PRIMARY KEY NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  relay_id TEXT NOT NULL,
  node TEXT NOT NULL,
  module TEXT NOT NULL,
  function TEXT NOT NULL,
  arity INTEGER NOT NULL CHECK (arity >= 0 AND arity <= 255),
  mode TEXT NOT NULL CHECK (mode IN ('exact', 'live', 'unknown')),
  started_at_ms INTEGER NOT NULL CHECK (started_at_ms >= 0),
  received_at_ms INTEGER NOT NULL CHECK (received_at_ms >= 0),
  ended_at_ms INTEGER NOT NULL DEFAULT 0 CHECK (ended_at_ms >= 0),
  last_received_at_ms INTEGER NOT NULL CHECK (last_received_at_ms >= 0),
  legal_hold INTEGER NOT NULL DEFAULT 0 CHECK (legal_hold IN (0, 1)),
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
);
CREATE UNIQUE INDEX IF NOT EXISTS relay_session_one_active
  ON relay_session_details(relay_id) WHERE active = 1;
CREATE INDEX IF NOT EXISTS relay_session_listing
  ON relay_session_details(received_at_ms DESC, session_id DESC);
CREATE TABLE IF NOT EXISTS relay_frames (
  session_id TEXT NOT NULL,
  relay_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence > 0),
  received_at_ms INTEGER NOT NULL CHECK (received_at_ms >= 0),
  mode TEXT NOT NULL CHECK (mode IN ('exact', 'live')),
  privacy TEXT NOT NULL CHECK (privacy IN ('metadata', 'raw', 'unknown')),
  blob_key TEXT NOT NULL,
  event_count INTEGER NOT NULL DEFAULT 1 CHECK (event_count >= 0),
  bytes INTEGER NOT NULL CHECK (bytes > 0 AND bytes <= 1048576),
  sha256 TEXT NOT NULL,
  PRIMARY KEY (session_id, sequence)
);
CREATE INDEX IF NOT EXISTS relay_frames_lookup
  ON relay_frames(relay_id, received_at_ms, sequence);
CREATE TABLE IF NOT EXISTS retention_blob_deletions (
  blob_key TEXT PRIMARY KEY NOT NULL,
  bytes INTEGER NOT NULL CHECK (bytes > 0 AND bytes <= 1048576)
);
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
CREATE TABLE IF NOT EXISTS raw_capture_grants (
  token_hash TEXT PRIMARY KEY NOT NULL,
  relay_id TEXT NOT NULL,
  actor TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
  expires_at_ms INTEGER NOT NULL CHECK (expires_at_ms > created_at_ms),
  max_events INTEGER NOT NULL CHECK (max_events > 0),
  used_events INTEGER NOT NULL DEFAULT 0 CHECK (
    used_events >= 0 AND used_events <= max_events
  ),
  max_bytes INTEGER NOT NULL CHECK (max_bytes > 0),
  used_bytes INTEGER NOT NULL DEFAULT 0 CHECK (
    used_bytes >= 0 AND used_bytes <= max_bytes
  ),
  policy_hash TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'exhausted', 'revoked'))
);
CREATE INDEX IF NOT EXISTS raw_capture_grants_relay
  ON raw_capture_grants(relay_id, expires_at_ms);
"

/// Install the current storage schema and migrate every supported historical
/// relay layout without discarding legacy frames.
pub fn apply(connection: sqlight.Connection) -> Result(Nil, String) {
  use Nil <- result_try(sqlight.exec(schema, connection) |> map_sql_error)
  use Nil <- result_try(ensure_relay_event_count(connection))
  use Nil <- result_try(ensure_relay_privacy(connection))
  use Nil <- result_try(ensure_relay_session_id(connection))
  use Nil <- result_try(ensure_relay_session_indexes(connection))
  use Nil <- result_try(migrate_legacy_relay_sessions(connection))
  sqlight.exec("PRAGMA user_version = 9;", connection) |> map_sql_error
}

fn ensure_relay_event_count(
  connection: sqlight.Connection,
) -> Result(Nil, String) {
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
      sqlight.exec(
        "ALTER TABLE relay_frames ADD COLUMN event_count INTEGER NOT NULL
         DEFAULT 1 CHECK (event_count >= 0);",
        connection,
      )
      |> map_sql_error
    Ok([1]) -> Ok(Nil)
    Ok(_) -> Error("invalid_relay_schema")
  }
}

fn ensure_relay_privacy(connection: sqlight.Connection) -> Result(Nil, String) {
  case
    sqlight.query(
      "SELECT COUNT(*) FROM pragma_table_info('relay_frames')
       WHERE name = 'privacy';",
      on: connection,
      with: [],
      expecting: count_decoder(),
    )
  {
    Error(error) -> Error(sql_error(error))
    Ok([0]) ->
      sqlight.exec(
        "ALTER TABLE relay_frames ADD COLUMN privacy TEXT NOT NULL
         DEFAULT 'unknown' CHECK (privacy IN ('metadata', 'raw', 'unknown'));",
        connection,
      )
      |> map_sql_error
    Ok([1]) -> Ok(Nil)
    Ok(_) -> Error("invalid_relay_schema")
  }
}

fn ensure_relay_session_id(
  connection: sqlight.Connection,
) -> Result(Nil, String) {
  case
    sqlight.query(
      "SELECT COUNT(*) FROM pragma_table_info('relay_frames')
       WHERE name = 'session_id';",
      on: connection,
      with: [],
      expecting: count_decoder(),
    )
  {
    Error(error) -> Error(sql_error(error))
    Ok([1]) -> Ok(Nil)
    Ok([0]) -> {
      use Nil <- result_try(reject_legacy_session_id_collisions(connection))
      sqlight.exec(
        "BEGIN IMMEDIATE;
         INSERT OR IGNORE INTO sessions (
           id, project, environment, created_at_ms, completeness,
           privacy, blob_key, event_count
         )
         SELECT 'legacy-' || relay_id, 'legacy', 'legacy',
                MIN(received_at_ms), 'incomplete', 'unknown',
                'sessions/legacy-' || relay_id || '/manifest.json',
                SUM(event_count)
         FROM relay_frames GROUP BY relay_id;
         INSERT OR IGNORE INTO relay_session_details (
           session_id, relay_id, node, module, function, arity, mode,
           started_at_ms, received_at_ms, ended_at_ms,
           last_received_at_ms, legal_hold, active
         )
         SELECT 'legacy-' || relay_id, relay_id, 'unknown', 'unknown',
                'unknown', 0, 'unknown', MIN(received_at_ms),
                MIN(received_at_ms), 0, MAX(received_at_ms), 0, 0
         FROM relay_frames GROUP BY relay_id;
         CREATE TABLE relay_frames_v2 (
           session_id TEXT NOT NULL,
           relay_id TEXT NOT NULL,
           sequence INTEGER NOT NULL CHECK (sequence > 0),
           received_at_ms INTEGER NOT NULL CHECK (received_at_ms >= 0),
           mode TEXT NOT NULL CHECK (mode IN ('exact', 'live')),
           privacy TEXT NOT NULL CHECK (privacy IN ('metadata', 'raw', 'unknown')),
           blob_key TEXT NOT NULL,
           event_count INTEGER NOT NULL DEFAULT 1 CHECK (event_count >= 0),
           bytes INTEGER NOT NULL CHECK (bytes > 0 AND bytes <= 1048576),
           sha256 TEXT NOT NULL,
           PRIMARY KEY (session_id, sequence)
         );
         INSERT INTO relay_frames_v2 (
           session_id, relay_id, sequence, received_at_ms, mode, privacy,
           blob_key, event_count, bytes, sha256
         )
         SELECT 'legacy-' || relay_id, relay_id, sequence, received_at_ms,
                mode, privacy, blob_key, event_count, bytes, sha256
         FROM relay_frames;
         DROP TABLE relay_frames;
         ALTER TABLE relay_frames_v2 RENAME TO relay_frames;
         CREATE INDEX relay_frames_lookup
           ON relay_frames(relay_id, received_at_ms, sequence);
         CREATE INDEX relay_frames_session_lookup
           ON relay_frames(session_id, sequence);
         COMMIT;",
        connection,
      )
      |> map_sql_error
    }
    Ok(_) -> Error("invalid_relay_schema")
  }
}

/// A v0.1.x session id was user-controlled. Never merge legacy relay frames
/// into an unrelated row that happens to use our synthetic id namespace.
/// Failing the migration leaves the old frame table intact for explicit
/// operator recovery instead of silently corrupting ownership or privacy.
fn reject_legacy_session_id_collisions(
  connection: sqlight.Connection,
) -> Result(Nil, String) {
  case
    sqlight.query(
      "SELECT COUNT(*) FROM sessions
       WHERE id IN (
         SELECT DISTINCT 'legacy-' || relay_id FROM relay_frames
       );",
      on: connection,
      with: [],
      expecting: count_decoder(),
    )
  {
    Error(error) -> Error(sql_error(error))
    Ok([0]) -> Ok(Nil)
    Ok([_]) -> Error("legacy_session_id_conflict")
    Ok(_) -> Error("invalid_relay_schema")
  }
}

fn migrate_legacy_relay_sessions(
  connection: sqlight.Connection,
) -> Result(Nil, String) {
  sqlight.exec(
    "INSERT OR IGNORE INTO sessions (
       id, project, environment, created_at_ms, completeness,
       privacy, blob_key, event_count
     )
     SELECT session_id, 'legacy', 'legacy', MIN(received_at_ms),
            'incomplete', 'unknown',
            'sessions/' || session_id || '/manifest.json', SUM(event_count)
     FROM relay_frames
     WHERE session_id LIKE 'legacy-%'
     GROUP BY session_id;
     INSERT OR IGNORE INTO relay_session_details (
       session_id, relay_id, node, module, function, arity, mode,
       started_at_ms, received_at_ms, ended_at_ms,
       last_received_at_ms, legal_hold, active
     )
     SELECT session_id, MIN(relay_id), 'unknown', 'unknown', 'unknown', 0,
            'unknown', MIN(received_at_ms), MIN(received_at_ms), 0,
            MAX(received_at_ms), 0, 0
     FROM relay_frames
     WHERE session_id LIKE 'legacy-%'
     GROUP BY session_id;
     INSERT OR IGNORE INTO event_segments (
       session_id, ordinal, first_event, event_count, blob_key, sha256
     )
     SELECT current.session_id, current.sequence,
            COALESCE((
              SELECT SUM(previous.event_count)
              FROM relay_frames AS previous
              WHERE previous.session_id = current.session_id
                AND previous.sequence < current.sequence
            ), 0),
            current.event_count, current.blob_key, current.sha256
     FROM relay_frames AS current
     WHERE current.session_id LIKE 'legacy-%' AND current.event_count > 0;
     UPDATE event_segments
     SET first_event = COALESCE((
       SELECT SUM(previous.event_count)
       FROM relay_frames AS previous
       WHERE previous.session_id = event_segments.session_id
         AND previous.sequence < event_segments.ordinal
     ), 0)
     WHERE event_segments.session_id LIKE 'legacy-%'
       AND EXISTS (
         SELECT 1 FROM relay_frames AS current
         WHERE current.session_id = event_segments.session_id
           AND current.sequence = event_segments.ordinal
       );",
    connection,
  )
  |> map_sql_error
}

fn ensure_relay_session_indexes(
  connection: sqlight.Connection,
) -> Result(Nil, String) {
  sqlight.exec(
    "CREATE INDEX IF NOT EXISTS relay_frames_session_lookup
       ON relay_frames(session_id, sequence);",
    connection,
  )
  |> map_sql_error
}

fn count_decoder() -> decode.Decoder(Int) {
  use count <- decode.field(0, decode.int)
  decode.success(count)
}

fn map_sql_error(result: Result(a, sqlight.Error)) -> Result(a, String) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(sql_error(error))
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

fn sql_error(error: sqlight.Error) -> String {
  string.inspect(error)
}
