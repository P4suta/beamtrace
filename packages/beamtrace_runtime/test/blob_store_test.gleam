// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import gleam/string
import gleeunit/should

pub fn immutable_blob_is_atomic_and_content_addressed_test() {
  let root = "build/beamtrace-blob-store-test"
  let key = "sessions/session-blob-test/events/000001.ndjson"
  let payload = "{\"event\":1}\n"

  let assert Ok(stored) = blob_store.put(root, key, payload)
  stored.key |> should.equal(key)
  stored.bytes |> should.equal(string.byte_size(payload))
  stored.sha256 |> string.length |> should.equal(64)
  blob_store.read(root, key) |> should.equal(Ok(payload))
  blob_store.read_verified(root, key, stored.sha256, stored.bytes)
  |> should.equal(Ok(payload))
  blob_store.read_verified(
    root,
    key,
    "0000000000000000000000000000000000000000000000000000000000000000",
    stored.bytes,
  )
  |> should.equal(Error("blob_checksum_mismatch"))
  blob_store.read_verified(root, key, stored.sha256, stored.bytes + 1)
  |> should.equal(Error("blob_checksum_mismatch"))

  // A retry with the same bytes is idempotent, but an existing key is immutable.
  blob_store.put(root, key, payload) |> should.equal(Ok(stored))
  blob_store.put(root, key, "different")
  |> should.equal(Error("blob_conflict"))
}

pub fn blob_store_rejects_traversal_absolute_and_unbounded_inputs_test() {
  let root = "build/beamtrace-blob-store-test"
  blob_store.put(root, "../outside", "secret")
  |> should.equal(Error("invalid_blob_key"))
  blob_store.put(root, "/absolute", "secret")
  |> should.equal(Error("invalid_blob_key"))
  blob_store.put(root, "windows\\outside", "secret")
  |> should.equal(Error("invalid_blob_key"))
  blob_store.put(root, "sessions/empty", "")
  |> should.equal(Error("invalid_blob_payload"))
}
