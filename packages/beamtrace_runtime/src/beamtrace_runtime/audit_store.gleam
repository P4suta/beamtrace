// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/audit
import beamtrace_runtime/team_store

pub type Store

@external(erlang, "beamtrace_audit_store_ffi", "new")
pub fn new() -> Store

pub fn persistent(database: team_store.Store) -> Result(Store, String) {
  case team_store.audit_log(database) {
    Error(reason) -> Error(reason)
    Ok(log) ->
      Ok(new_with_persistence(log, fn(next) { persist_latest(database, next) }))
  }
}

@external(erlang, "beamtrace_audit_store_ffi", "new_with_persistence")
fn new_with_persistence(
  initial: audit.AuditLog,
  persist: fn(audit.AuditLog) -> Result(Nil, String),
) -> Store

@external(erlang, "beamtrace_audit_store_ffi", "append")
pub fn append(
  store: Store,
  timestamp_ms: Int,
  actor: String,
  action: String,
  resource: String,
  outcome: String,
) -> Nil

/// Append an entry only if its caller-provided durable transaction succeeds.
/// The store advances its in-memory chain after the transaction commits, so
/// privileged state and its audit evidence cannot diverge.
@external(erlang, "beamtrace_audit_store_ffi", "append_transactional")
pub fn append_transactional(
  store: Store,
  timestamp_ms: Int,
  actor: String,
  action: String,
  resource: String,
  outcome: String,
  persist: fn(audit.AuditLog) -> Result(value, String),
) -> Result(value, String)

@external(erlang, "beamtrace_audit_store_ffi", "snapshot")
pub fn snapshot(store: Store) -> audit.AuditLog

@external(erlang, "beamtrace_audit_store_ffi", "close")
pub fn close(store: Store) -> Nil

fn persist_latest(
  database: team_store.Store,
  log: audit.AuditLog,
) -> Result(Nil, String) {
  case last_entry(log.entries) {
    Error(_) -> Error("missing_audit_entry")
    Ok(entry) -> team_store.put_audit_entry(database, entry)
  }
}

fn last_entry(
  entries: List(audit.AuditEntry),
) -> Result(audit.AuditEntry, Nil) {
  case entries {
    [] -> Error(Nil)
    [entry] -> Ok(entry)
    [_, ..rest] -> last_entry(rest)
  }
}
