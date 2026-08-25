// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/team_store
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should

pub fn accepted_frame_is_durable_and_readable_after_reopen_test() {
  let database = "build/beamtrace-relay-archive-test.sqlite3"
  let blobs = "build/beamtrace-relay-archive-blobs"
  let relay_id = "relay-00112233445566778899aabb"
  let payload = "{\"type\":\"batch\",\"mode\":\"exact\"}"

  let assert Ok(store) = team_store.open(database)
  let assert Ok(frame) =
    relay_archive.persist(
      store,
      blobs,
      relay_id,
      1,
      relay_archive.Exact,
      payload,
      1234,
    )
  frame.privacy |> should.equal("unknown")
  team_store.close(store) |> should.equal(Ok(Nil))

  let assert Ok(reopened) = team_store.open(database)
  team_store.relay_frame(reopened, relay_id, 1)
  |> should.equal(Ok(Some(frame)))
  relay_archive.read_payload(blobs, frame) |> should.equal(Ok(payload))
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

pub fn relay_archive_backend_adapter_preserves_immutable_verified_contract_test() {
  let assert Ok(store) = team_store.open(":memory:")
  let backend = blob_store.filesystem("build/beamtrace-relay-backend-adapter")
  let relay_id = "relay-00112233445566778899aabb"
  let assert Ok(frame) =
    relay_archive.persist_with(
      store,
      backend,
      relay_id,
      1,
      relay_archive.Exact,
      "backend-payload",
      100,
    )
  relay_archive.read_payload_with(backend, frame)
  |> should.equal(Ok("backend-payload"))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn relay_frame_sequence_cannot_be_replaced_with_other_content_test() {
  let assert Ok(store) = team_store.open(":memory:")
  let blobs = "build/beamtrace-relay-conflict-blobs"
  let relay_id = "relay-ffeeddccbbaa998877665544"
  relay_archive.persist(
    store,
    blobs,
    relay_id,
    1,
    relay_archive.Live,
    "{\"type\":\"batch\",\"mode\":\"live\"}",
    1234,
  )
  |> should.be_ok

  relay_archive.persist(
    store,
    blobs,
    relay_id,
    1,
    relay_archive.Live,
    "different",
    1235,
  )
  |> should.equal(Error("blob_conflict"))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn conflicting_retry_never_deletes_the_existing_immutable_blob_test() {
  let assert Ok(store) = team_store.open(":memory:")
  let backend =
    blob_store.filesystem("build/beamtrace-relay-existing-blob-regression")
  let relay_id = "relay-0f0e0d0c0b0a090807060504"
  let payload = "same-immutable-payload"
  let assert Ok(existing) =
    relay_archive.persist_events_classified_with(
      store,
      backend,
      relay_id,
      1,
      relay_archive.Exact,
      relay_inbox.Unknown,
      payload,
      1234,
      event_count: 1,
    )

  relay_archive.persist_events_classified_with(
    store,
    backend,
    relay_id,
    1,
    relay_archive.Exact,
    relay_inbox.Metadata,
    payload,
    1235,
    event_count: 1,
  )
  |> should.equal(Error("relay_frame_conflict"))
  relay_archive.read_payload_with(backend, existing)
  |> should.equal(Ok(payload))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn retention_prunes_index_and_blob_in_bounded_batches_test() {
  let assert Ok(store) = team_store.open(":memory:")
  let blobs = "build/beamtrace-relay-retention-blobs"
  let relay_id = "relay-11223344556677889900aabb"
  relay_archive.persist(
    store,
    blobs,
    relay_id,
    1,
    relay_archive.Live,
    "old-one",
    100,
  )
  |> should.be_ok
  relay_archive.persist(
    store,
    blobs,
    relay_id,
    2,
    relay_archive.Live,
    "old-two",
    200,
  )
  |> should.be_ok
  let assert Ok(fresh) =
    relay_archive.persist(
      store,
      blobs,
      relay_id,
      3,
      relay_archive.Live,
      "fresh",
      300,
    )

  relay_archive.prune_before(store, blobs, cutoff_ms: 250, limit: 1)
  |> should.equal(Ok(relay_archive.PruneResult(1, 7, True)))
  team_store.relay_frame(store, relay_id, 1)
  |> should.equal(Ok(None))

  relay_archive.prune_before(store, blobs, cutoff_ms: 250, limit: 10)
  |> should.equal(Ok(relay_archive.PruneResult(1, 7, False)))
  team_store.relay_frame(store, relay_id, 2)
  |> should.equal(Ok(None))
  team_store.relay_frame(store, relay_id, 3)
  |> should.equal(Ok(Some(fresh)))
  relay_archive.read_payload(blobs, fresh) |> should.equal(Ok("fresh"))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn session_retention_uses_hub_receive_time_privacy_and_legal_hold_test() {
  let assert Ok(store) = team_store.open(":memory:")
  let backend = blob_store.filesystem("build/beamtrace-session-retention-blobs")
  let metadata =
    trace_start(
      "10000000000000000000000000000001",
      "relay-100000000000000000000001",
      "metadata",
      started_at_ms: 0,
      received_at_ms: 500,
    )
  let raw =
    trace_start(
      "20000000000000000000000000000002",
      "relay-200000000000000000000002",
      "raw",
      started_at_ms: 10_000,
      received_at_ms: 500,
    )
  let held =
    trace_start(
      "30000000000000000000000000000003",
      "relay-300000000000000000000003",
      "raw",
      started_at_ms: 0,
      received_at_ms: 50,
    )
  let received_late =
    trace_start(
      "40000000000000000000000000000004",
      "relay-400000000000000000000004",
      "metadata",
      started_at_ms: 0,
      received_at_ms: 1000,
    )
  let metadata_expired =
    trace_start(
      "50000000000000000000000000000005",
      "relay-500000000000000000000005",
      "metadata",
      started_at_ms: 10_000,
      received_at_ms: 50,
    )

  let assert Ok(metadata_frame) = seed_trace(store, backend, metadata, "meta")
  let assert Ok(raw_frame) = seed_trace(store, backend, raw, "raw")
  let assert Ok(held_frame) = seed_trace(store, backend, held, "held")
  let assert Ok(late_frame) = seed_trace(store, backend, received_late, "late")
  let assert Ok(expired_frame) =
    seed_trace(store, backend, metadata_expired, "expired")
  let assert Ok(_) = team_store.set_trace_legal_hold(store, held.id, True)

  let assert Ok(result) =
    relay_archive.prune_sessions_before_with(
      store,
      backend,
      metadata_cutoff_ms: 100,
      raw_cutoff_ms: 900,
      limit: 100,
    )
  result.deleted_frames |> should.equal(2)
  result.more |> should.be_false()
  team_store.retention_blob_deletions(store, limit: 10)
  |> should.equal(Ok([]))

  team_store.trace_session(store, raw.id) |> should.equal(Ok(None))
  team_store.trace_session(store, metadata_expired.id) |> should.equal(Ok(None))
  relay_archive.read_payload_with(backend, raw_frame) |> should.be_error()
  relay_archive.read_payload_with(backend, expired_frame) |> should.be_error()

  let assert Ok(Some(_metadata_session)) =
    team_store.trace_session(store, metadata.id)
  let assert Ok(Some(held_session)) = team_store.trace_session(store, held.id)
  held_session.legal_hold |> should.be_true()
  let assert Ok(Some(_late_session)) =
    team_store.trace_session(store, received_late.id)
  relay_archive.read_payload_with(backend, metadata_frame)
  |> should.equal(Ok("meta"))
  relay_archive.read_payload_with(backend, held_frame)
  |> should.equal(Ok("held"))
  relay_archive.read_payload_with(backend, late_frame)
  |> should.equal(Ok("late"))
  team_store.close(store) |> should.equal(Ok(Nil))
}

fn seed_trace(
  store: team_store.Store,
  backend: blob_store.Backend,
  session: team_store.TraceSession,
  payload: String,
) -> Result(team_store.RelayFrameIndex, String) {
  use _ <- result.try(team_store.begin_trace_session(store, session, 64))
  use frame <- result.try(relay_archive.persist_session_events_classified_with(
    store,
    backend,
    session.id,
    session.relay_id,
    1,
    relay_archive.Exact,
    case session.privacy {
      "metadata" -> relay_inbox.Metadata
      _ -> relay_inbox.Raw
    },
    payload,
    session.received_at_ms + 1,
    event_count: 1,
  ))
  use _ <- result.try(team_store.finish_trace_session(
    store,
    session.id,
    session.relay_id,
    "delivered",
    session.received_at_ms + 2,
    session.received_at_ms + 3,
  ))
  Ok(frame)
}

fn trace_start(
  id: String,
  relay_id: String,
  privacy: String,
  started_at_ms started_at_ms: Int,
  received_at_ms received_at_ms: Int,
) -> team_store.TraceSession {
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
    privacy: privacy,
    started_at_ms: started_at_ms,
    received_at_ms: received_at_ms,
    ended_at_ms: 0,
    last_received_at_ms: received_at_ms,
    delivery_status: "active",
    event_count: 0,
    legal_hold: False,
    active: True,
  )
}
