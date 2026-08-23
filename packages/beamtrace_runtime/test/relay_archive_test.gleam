// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/relay_archive
import beamtrace_runtime/team_store
import gleam/option.{None, Some}
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
