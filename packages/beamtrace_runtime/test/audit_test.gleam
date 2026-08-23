// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/audit
import gleam/list
import gleeunit/should

pub fn audit_log_is_hash_chained_and_verifiable_test() {
  let log =
    audit.new()
    |> audit.append(1000, "alice", "capture.start", "session:one", "allowed")
    |> audit.append(1100, "relay-7", "capture.stop", "session:one", "complete")

  audit.verify(log) |> should.equal(Ok(Nil))
  list.length(log.entries) |> should.equal(2)
  let assert [first, second] = log.entries
  first.previous_hash |> should.equal(audit.genesis_hash)
  second.previous_hash |> should.equal(first.hash)
  log.head_hash |> should.equal(second.hash)
}

pub fn audit_log_detects_modified_and_reordered_entries_test() {
  let log =
    audit.new()
    |> audit.append(
      1000,
      "alice",
      "raw_capture.start",
      "session:one",
      "allowed",
    )
    |> audit.append(
      1100,
      "alice",
      "raw_capture.stop",
      "session:one",
      "complete",
    )

  let assert [first, second] = log.entries
  let modified =
    audit.AuditLog(
      [audit.AuditEntry(..first, outcome: "denied"), second],
      log.head_hash,
    )
  audit.verify(modified) |> should.equal(Error(audit.HashMismatch(1)))

  let reordered = audit.AuditLog([second, first], log.head_hash)
  audit.verify(reordered) |> should.equal(Error(audit.SequenceMismatch(1)))
}

pub fn audit_log_detects_truncated_tail_test() {
  let log =
    audit.new()
    |> audit.append(1000, "alice", "capture.start", "session:one", "allowed")
    |> audit.append(1100, "alice", "capture.stop", "session:one", "complete")

  let assert [first, _] = log.entries
  let truncated = audit.AuditLog([first], log.head_hash)
  audit.verify(truncated) |> should.equal(Error(audit.HeadMismatch))
}
