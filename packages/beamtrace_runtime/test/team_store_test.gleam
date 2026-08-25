// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/audit
import beamtrace_runtime/relay_channel
import beamtrace_runtime/team_store
import gleam/option.{None, Some}
import gleam/string
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

pub fn relay_sessions_are_bounded_immutable_and_restart_safe_test() {
  let path = fresh_store_path()
  let relay_id = "relay-11223344556677889900aabb"
  let start = trace_start("00112233445566778899aabbccddeeff", relay_id)
  let assert Ok(store) = team_store.open(path)
  team_store.begin_trace_session(store, start, 1) |> should.equal(Ok(start))
  team_store.begin_trace_session(store, start, 1)
  |> should.equal(Error("relay_session_active"))
  team_store.begin_trace_session(
    store,
    team_store.TraceSession(..start, node: "different@host"),
    1,
  )
  |> should.equal(Error("session_metadata_conflict"))
  team_store.begin_trace_session(
    store,
    trace_start(
      "ffeeddccbbaa99887766554433221100",
      "relay-aabbccddeeff001122334455",
    ),
    1,
  )
  |> should.equal(Error("active_session_limit"))
  let assert Ok(finished) =
    team_store.finish_trace_session(
      store,
      start.id,
      relay_id,
      "complete",
      1600,
      1700,
    )
  finished.completeness |> should.equal("complete")
  finished.active |> should.be_false()
  team_store.begin_trace_session(store, start, 1)
  |> should.equal(Error("session_already_ended"))
  team_store.close(store) |> should.equal(Ok(Nil))

  let assert Ok(reopened) = team_store.open(path)
  team_store.trace_session(reopened, start.id)
  |> should.equal(Ok(Some(finished)))
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

pub fn disconnected_session_resume_obeys_global_limit_and_relay_identity_test() {
  let first =
    trace_start(
      "10000000000000000000000000000001",
      "relay-11223344556677889900aabb",
    )
  let second =
    trace_start(
      "20000000000000000000000000000002",
      "relay-aabbccddeeff001122334455",
    )
  let assert Ok(store) = team_store.open(":memory:")
  let assert Ok(_) = team_store.begin_trace_session(store, first, 1)

  team_store.mark_trace_incomplete(
    store,
    first.id,
    "relay-000000000000000000000000",
    1200,
  )
  |> should.equal(Ok(Nil))
  let assert Ok(Some(still_active)) = team_store.trace_session(store, first.id)
  still_active.active |> should.be_true()
  still_active.completeness |> should.equal("active")

  team_store.mark_trace_incomplete(store, first.id, first.relay_id, 1200)
  |> should.equal(Ok(Nil))
  let assert Ok(Some(disconnected)) = team_store.trace_session(store, first.id)
  disconnected.active |> should.be_false()
  disconnected.completeness |> should.equal("incomplete")

  let assert Ok(_) = team_store.begin_trace_session(store, second, 1)
  team_store.begin_trace_session(
    store,
    team_store.TraceSession(
      ..first,
      received_at_ms: 1300,
      last_received_at_ms: 1300,
    ),
    1,
  )
  |> should.equal(Error("active_session_limit"))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn disconnected_session_resumes_only_with_identical_immutable_metadata_test() {
  let start =
    trace_start(
      "30000000000000000000000000000003",
      "relay-00112233445566778899aabb",
    )
  let assert Ok(store) = team_store.open(":memory:")
  let assert Ok(_) = team_store.begin_trace_session(store, start, 64)
  team_store.mark_trace_incomplete(store, start.id, start.relay_id, 1200)
  |> should.equal(Ok(Nil))

  team_store.begin_trace_session(
    store,
    team_store.TraceSession(
      ..start,
      node: "changed@host",
      received_at_ms: 1300,
      last_received_at_ms: 1300,
    ),
    64,
  )
  |> should.equal(Error("session_metadata_conflict"))

  let assert Ok(resumed) =
    team_store.begin_trace_session(
      store,
      team_store.TraceSession(
        ..start,
        received_at_ms: 1400,
        last_received_at_ms: 1400,
      ),
      64,
    )
  resumed.active |> should.be_true()
  resumed.completeness |> should.equal("active")
  resumed.last_received_at_ms |> should.equal(1400)
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn session_frames_atomically_feed_existing_segments_and_counts_test() {
  let relay_id = "relay-11223344556677889900aabb"
  let start = trace_start("0123456789abcdef0123456789abcdef", relay_id)
  let assert Ok(store) = team_store.open(":memory:")
  let assert Ok(_) = team_store.begin_trace_session(store, start, 64)
  let first = trace_frame(start.id, relay_id, 2, 3, 1200)
  team_store.put_trace_frame(store, first) |> should.equal(Ok(first))
  team_store.put_trace_frame(store, first) |> should.equal(Ok(first))
  let second = trace_frame(start.id, relay_id, 3, 2, 1300)
  team_store.put_trace_frame(store, second) |> should.equal(Ok(second))

  let assert Ok(Some(indexed)) = team_store.trace_session(store, start.id)
  indexed.event_count |> should.equal(5)
  indexed.last_received_at_ms |> should.equal(1300)
  team_store.trace_usage(store, start.id) |> should.equal(Ok(#(5, 50)))
  team_store.trace_frames(store, start.id, start: 0, limit: 10)
  |> should.equal(Ok([first, second]))
  team_store.segments(store, start.id)
  |> should.equal(
    Ok([
      team_store.SegmentIndex(start.id, 2, 0, 3, first.blob_key, first.sha256),
      team_store.SegmentIndex(start.id, 3, 3, 2, second.blob_key, second.sha256),
    ]),
  )
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn retention_rechecks_hold_and_persists_blob_outbox_across_restart_test() {
  let path = fresh_store_path()
  let relay_id = "relay-99aabbccddeeff0011223344"
  let start = trace_start("99aabbccddeeff001122334455667788", relay_id)
  let frame = trace_frame(start.id, relay_id, 1, 2, 1200)
  let assert Ok(store) = team_store.open(path)
  let assert Ok(_) = team_store.begin_trace_session(store, start, 64)
  team_store.put_trace_frame(store, frame) |> should.equal(Ok(frame))
  let assert Ok(_) =
    team_store.finish_trace_session(
      store,
      start.id,
      relay_id,
      "complete",
      1600,
      1700,
    )

  // Simulate a retention worker holding a stale candidate while an Admin
  // successfully enables legal hold. The transactional recheck must win.
  let assert Ok([candidate]) =
    team_store.expired_trace_sessions(
      store,
      metadata_cutoff_ms: 2000,
      raw_cutoff_ms: 2000,
      limit: 10,
    )
  candidate.id |> should.equal(start.id)
  let assert Ok(held) = team_store.set_trace_legal_hold(store, start.id, True)
  held.legal_hold |> should.be_true()
  team_store.prepare_expired_trace_session_deletion(store, candidate.id)
  |> should.equal(Error("trace_retention_protected"))
  team_store.retention_blob_deletions(store, limit: 10)
  |> should.equal(Ok([]))

  let assert Ok(_) = team_store.set_trace_legal_hold(store, start.id, False)
  team_store.prepare_expired_trace_session_deletion(store, start.id)
  |> should.equal(Ok([team_store.RetentionBlob(frame.blob_key, frame.bytes)]))
  team_store.trace_session(store, start.id) |> should.equal(Ok(None))
  team_store.close(store) |> should.equal(Ok(Nil))

  // The outbox, unlike the removed trace indexes, survives a process restart.
  let assert Ok(reopened) = team_store.open(path)
  team_store.retention_blob_deletions(reopened, limit: 10)
  |> should.equal(Ok([team_store.RetentionBlob(frame.blob_key, frame.bytes)]))
  team_store.complete_retention_blob_deletion(reopened, frame.blob_key)
  |> should.equal(Ok(Nil))
  team_store.retention_blob_deletions(reopened, limit: 10)
  |> should.equal(Ok([]))
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

pub fn legal_hold_and_audit_chain_commit_or_rollback_together_test() {
  let relay_id = "relay-77aabbccddeeff0011223344"
  let start = trace_start("77aabbccddeeff001122334455667788", relay_id)
  let assert Ok(store) = team_store.open(":memory:")
  let assert Ok(_) = team_store.begin_trace_session(store, start, 64)
  let created =
    audit.new()
    |> audit.append(
      2100,
      "admin",
      "trace.hold.create",
      "trace:" <> start.id,
      "allowed",
    )

  let assert Ok(held) =
    team_store.set_trace_legal_hold_audited(store, start.id, True, created)
  held.legal_hold |> should.be_true()
  team_store.audit_log(store) |> should.equal(Ok(created))

  // Reusing a conflicting sequence must roll back the hold transition as
  // well as the forged audit entry.
  let conflicting =
    audit.new()
    |> audit.append(
      2101,
      "admin",
      "trace.hold.delete",
      "trace:" <> start.id,
      "allowed",
    )
  team_store.set_trace_legal_hold_audited(store, start.id, False, conflicting)
  |> should.equal(Error("audit_log_conflict"))
  let assert Ok(Some(still_held)) = team_store.trace_session(store, start.id)
  still_held.legal_hold |> should.be_true()
  team_store.audit_log(store) |> should.equal(Ok(created))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn sqlite_wal_store_persists_relay_frame_indexes_test() {
  let path = "build/beamtrace-relay-index-v7-test.sqlite3"
  let frame =
    team_store.RelayFrameIndex(
      session_id: "legacy-relay-aabbccddeeff001122334455",
      relay_id: "relay-aabbccddeeff001122334455",
      sequence: 7,
      received_at_ms: 2000,
      mode: "exact",
      privacy: "metadata",
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
  team_store.relay_usage(store, relay_id) |> should.equal(Ok(#(2, 11)))
  let assert Ok(Some(frame)) = team_store.relay_frame(store, relay_id, 1)
  frame.event_count |> should.equal(1)
  frame.privacy |> should.equal("unknown")
  let trace_id = "legacy-" <> relay_id
  let assert Ok([first, second]) = team_store.segments(store, trace_id)
  first.first_event |> should.equal(0)
  second.first_event |> should.equal(1)
  second.ordinal |> should.equal(2)
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn legacy_relay_migration_refuses_a_synthetic_session_id_collision_test() {
  let path = legacy_relay_store_with_session_collision()
  team_store.open(path) |> should.equal(Error("legacy_session_id_conflict"))
  // The failure is stable and never turns into an idempotent-looking merge on
  // restart. An operator must resolve the collision explicitly.
  team_store.open(path) |> should.equal(Error("legacy_session_id_conflict"))
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

pub fn raw_capture_grants_are_persistent_and_reserve_budget_atomically_test() {
  let path = fresh_store_path()
  let grant =
    team_store.RawCaptureGrant(
      token_hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      relay_id: "relay-11223344556677889900aabb",
      actor: "investigator-raw",
      created_at_ms: 10_000,
      expires_at_ms: 20_000,
      max_events: 3,
      used_events: 0,
      max_bytes: 1000,
      used_bytes: 0,
      policy_hash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      status: "active",
    )
  let assert Ok(store) = team_store.open(path)
  team_store.put_raw_capture_grant(store, grant) |> should.equal(Ok(Nil))
  team_store.reserve_raw_capture_grant(
    store,
    grant.token_hash,
    grant.relay_id,
    grant.policy_hash,
    events: 2,
    bytes: 400,
    now_ms: 15_000,
  )
  |> should.equal(Ok(Nil))
  team_store.close(store) |> should.equal(Ok(Nil))

  let assert Ok(reopened) = team_store.open(path)
  let assert Ok(Some(saved)) =
    team_store.raw_capture_grant(reopened, grant.token_hash)
  saved.used_events |> should.equal(2)
  saved.used_bytes |> should.equal(400)
  team_store.reserve_raw_capture_grant(
    reopened,
    grant.token_hash,
    grant.relay_id,
    grant.policy_hash,
    events: 2,
    bytes: 1,
    now_ms: 15_001,
  )
  |> should.equal(Error("raw_capture_grant_denied"))
  team_store.reserve_raw_capture_grant(
    reopened,
    grant.token_hash,
    grant.relay_id,
    grant.policy_hash,
    events: 1,
    bytes: 1,
    now_ms: 20_001,
  )
  |> should.equal(Error("raw_capture_grant_denied"))
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

@external(erlang, "beamtrace_team_store_migration_test_ffi", "legacy_relay_store")
fn legacy_relay_store() -> String

@external(erlang, "beamtrace_team_store_migration_test_ffi", "legacy_relay_store_with_session_collision")
fn legacy_relay_store_with_session_collision() -> String

@external(erlang, "beamtrace_team_store_migration_test_ffi", "fresh_store_path")
fn fresh_store_path() -> String

fn trace_start(id: String, relay_id: String) -> team_store.TraceSession {
  team_store.TraceSession(
    id: id,
    relay_id: relay_id,
    project: "shop",
    environment: "prod",
    node: "fixture@host",
    module_: "shop",
    function_: "checkout",
    arity: 1,
    mode: "exact",
    privacy: "metadata",
    started_at_ms: 1000,
    received_at_ms: 1100,
    ended_at_ms: 0,
    last_received_at_ms: 1100,
    completeness: "active",
    event_count: 0,
    legal_hold: False,
    active: True,
  )
}

fn trace_frame(
  session_id: String,
  relay_id: String,
  sequence: Int,
  event_count: Int,
  received_at_ms: Int,
) -> team_store.RelayFrameIndex {
  team_store.RelayFrameIndex(
    session_id: session_id,
    relay_id: relay_id,
    sequence: sequence,
    received_at_ms: received_at_ms,
    mode: "exact",
    privacy: "metadata",
    blob_key: "sessions/"
      <> session_id
      <> "/events/"
      <> string.inspect(sequence)
      <> ".json",
    event_count: event_count,
    bytes: 25,
    sha256: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
  )
}
