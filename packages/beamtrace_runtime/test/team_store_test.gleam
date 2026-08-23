// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/audit
import beamtrace_runtime/relay_channel
import beamtrace_runtime/team_store
import gleam/option.{Some}
import gleeunit/should

pub fn sqlite_wal_store_persists_session_metadata_and_segment_indexes_test() {
  let path = "build/beamtrace-team-store-test.sqlite3"
  let metadata =
    team_store.SessionMetadata(
      id: "session-wal-test",
      project: "shop'; SELECT 1; --",
      environment: "prod",
      created_at_ms: 1000,
      completeness: "complete",
      privacy: "metadata",
      blob_key: "sessions/session-wal-test/capture.beamtrace",
      event_count: 1001,
    )
  let segment =
    team_store.SegmentIndex(
      session_id: metadata.id,
      ordinal: 1,
      first_event: 0,
      event_count: 1000,
      blob_key: "sessions/session-wal-test/events/000001.ndjson",
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    )

  let assert Ok(store) = team_store.open(path)
  team_store.journal_mode(store) |> should.equal(Ok("wal"))
  team_store.put_session(store, metadata) |> should.equal(Ok(Nil))
  team_store.put_segment(store, segment) |> should.equal(Ok(Nil))
  team_store.close(store) |> should.equal(Ok(Nil))

  let assert Ok(reopened) = team_store.open(path)
  team_store.get_session(reopened, metadata.id)
  |> should.equal(Ok(Some(metadata)))
  team_store.segments(reopened, metadata.id)
  |> should.equal(Ok([segment]))
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

pub fn sqlite_store_rejects_unsafe_or_unbounded_metadata_before_query_test() {
  let assert Ok(store) = team_store.open(":memory:")
  team_store.put_session(
    store,
    team_store.SessionMetadata(
      id: "session-invalid",
      project: "shop",
      environment: "prod",
      created_at_ms: 1000,
      completeness: "complete",
      privacy: "metadata",
      blob_key: "../outside.beamtrace",
      event_count: 1,
    ),
  )
  |> should.equal(Error("invalid_session_metadata"))

  team_store.get_session(store, "")
  |> should.equal(Error("invalid_session_id"))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn sqlite_wal_store_persists_relay_frame_indexes_test() {
  let path = "build/beamtrace-relay-index-v3-test.sqlite3"
  let frame =
    team_store.RelayFrameIndex(
      relay_id: "relay-aabbccddeeff001122334455",
      sequence: 7,
      received_at_ms: 2000,
      mode: "exact",
      blob_key: "relays/relay-aabbccddeeff001122334455/frames/7.json",
      event_count: 3,
      bytes: 25,
      sha256: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
    )

  let assert Ok(store) = team_store.open(path)
  team_store.put_relay_frame(store, frame) |> should.equal(Ok(Nil))
  team_store.close(store) |> should.equal(Ok(Nil))

  let assert Ok(reopened) = team_store.open(path)
  team_store.relay_frames(
    reopened,
    "relay-aabbccddeeff001122334455",
    start: 0,
    limit: 10,
  )
  |> should.equal(Ok([frame]))
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

pub fn schema_v2_relay_frames_migrate_with_conservative_event_counts_test() {
  let path = legacy_relay_store()
  let relay_id = "relay-00112233445566778899aabb"
  let assert Ok(store) = team_store.open(path)
  team_store.relay_usage(store, relay_id) |> should.equal(Ok(#(1, 5)))
  let assert Ok(Some(frame)) = team_store.relay_frame(store, relay_id, 1)
  frame.event_count |> should.equal(1)
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn sqlite_store_persists_annotations_and_hash_chained_audit_test() {
  let path = fresh_store_path()
  let assert Ok(store) = team_store.open(path)
  let assert Ok(first) =
    team_store.append_annotation(
      store,
      "event-durable-1",
      "restart evidence",
      "investigator-1",
      2000,
    )
  first.id |> should.equal("annotation-1")
  let log =
    audit.new()
    |> audit.append(
      2001,
      "investigator-1",
      "annotation.create",
      "event:event-durable-1",
      "allowed",
    )
  let assert [entry] = log.entries
  team_store.put_audit_entry(store, entry) |> should.equal(Ok(Nil))
  team_store.close(store) |> should.equal(Ok(Nil))

  let assert Ok(reopened) = team_store.open(path)
  team_store.annotations(reopened) |> should.equal(Ok([first]))
  team_store.audit_log(reopened) |> should.equal(Ok(log))
  let assert Ok(second) =
    team_store.append_annotation(
      reopened,
      "event-durable-2",
      "second note",
      "investigator-2",
      2002,
    )
  second.id |> should.equal("annotation-2")
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

pub fn sqlite_store_rejects_a_shape_valid_but_broken_audit_chain_test() {
  let path = fresh_store_path()
  let assert Ok(store) = team_store.open(path)
  let original =
    audit.new()
    |> audit.append(4000, "admin", "relay.enroll", "relay:new", "allowed")
  let assert [first] = original.entries
  team_store.put_audit_entry(store, first) |> should.equal(Ok(Nil))
  let forged =
    audit.AuditEntry(
      sequence: 2,
      timestamp_ms: 4001,
      actor: "attacker",
      action: "audit.rewrite",
      resource: "audit:1",
      outcome: "allowed",
      previous_hash: audit.genesis_hash,
      hash: first.hash,
    )
  team_store.put_audit_entry(store, forged) |> should.equal(Ok(Nil))
  team_store.audit_log(store) |> should.equal(Error("invalid_audit_chain"))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn sqlite_store_persists_relay_public_keys_without_private_material_test() {
  let path = fresh_store_path()
  let public_key = relay_channel.new_identity().public_key
  let identity =
    team_store.RelayIdentity(
      id: "relay-11223344556677889900aabb",
      algorithm: "Ed25519",
      public_key: public_key,
      enrolled_at_ms: 5000,
    )
  let assert Ok(store) = team_store.open(path)
  team_store.put_relay_identity(store, identity) |> should.equal(Ok(Nil))
  team_store.close(store) |> should.equal(Ok(Nil))

  let assert Ok(reopened) = team_store.open(path)
  team_store.relay_identities(reopened) |> should.equal(Ok([identity]))
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

@external(erlang, "beamtrace_team_store_migration_test_ffi", "legacy_relay_store")
fn legacy_relay_store() -> String

@external(erlang, "beamtrace_team_store_migration_test_ffi", "fresh_store_path")
fn fresh_store_path() -> String
