// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/crypto
import gleam/int
import gleam/list
import gleam/string

pub const genesis_hash = "0000000000000000000000000000000000000000000000000000000000000000"

pub type AuditEntry {
  AuditEntry(
    sequence: Int,
    timestamp_ms: Int,
    actor: String,
    action: String,
    resource: String,
    outcome: String,
    previous_hash: String,
    hash: String,
  )
}

pub type AuditLog {
  AuditLog(entries: List(AuditEntry), head_hash: String)
}

pub type AuditError {
  SequenceMismatch(expected: Int)
  PreviousHashMismatch(sequence: Int)
  HashMismatch(sequence: Int)
  HeadMismatch
}

pub fn new() -> AuditLog {
  AuditLog([], genesis_hash)
}

pub fn append(
  log: AuditLog,
  timestamp_ms: Int,
  actor: String,
  action: String,
  resource: String,
  outcome: String,
) -> AuditLog {
  let sequence = list.length(log.entries) + 1
  let hash =
    entry_hash(
      sequence,
      timestamp_ms,
      actor,
      action,
      resource,
      outcome,
      log.head_hash,
    )
  let entry =
    AuditEntry(
      sequence,
      timestamp_ms,
      actor,
      action,
      resource,
      outcome,
      log.head_hash,
      hash,
    )
  AuditLog(list.append(log.entries, [entry]), hash)
}

pub fn verify(log: AuditLog) -> Result(Nil, AuditError) {
  case verify_entries(log.entries, 1, genesis_hash) {
    Error(error) -> Error(error)
    Ok(calculated_head) ->
      case calculated_head == log.head_hash {
        True -> Ok(Nil)
        False -> Error(HeadMismatch)
      }
  }
}

fn verify_entries(
  entries: List(AuditEntry),
  expected_sequence: Int,
  previous_hash: String,
) -> Result(String, AuditError) {
  case entries {
    [] -> Ok(previous_hash)
    [entry, ..rest] ->
      case
        entry.sequence == expected_sequence,
        entry.previous_hash == previous_hash
      {
        False, _ -> Error(SequenceMismatch(expected_sequence))
        _, False -> Error(PreviousHashMismatch(entry.sequence))
        True, True -> {
          let calculated =
            entry_hash(
              entry.sequence,
              entry.timestamp_ms,
              entry.actor,
              entry.action,
              entry.resource,
              entry.outcome,
              entry.previous_hash,
            )
          case calculated == entry.hash {
            False -> Error(HashMismatch(entry.sequence))
            True -> verify_entries(rest, expected_sequence + 1, entry.hash)
          }
        }
      }
  }
}

fn entry_hash(
  sequence: Int,
  timestamp_ms: Int,
  actor: String,
  action: String,
  resource: String,
  outcome: String,
  previous_hash: String,
) -> String {
  [
    int.to_string(sequence),
    int.to_string(timestamp_ms),
    frame(actor),
    frame(action),
    frame(resource),
    frame(outcome),
    previous_hash,
  ]
  |> string.join("|")
  |> crypto.sha256_hex
}

fn frame(value: String) -> String {
  int.to_string(string.length(value)) <> ":" <> value
}
