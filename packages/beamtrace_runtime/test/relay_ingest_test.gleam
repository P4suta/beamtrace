// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_ingest
import beamtrace_runtime/team_store
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

fn event(index: Int) -> types.TraceEvent {
  types.TraceEvent(
    id: "event-" <> int.to_string(index),
    root_id: "root-1",
    node: "fixture@host",
    process: types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", "<0.1.0>"),
      logical: None,
      evidence: [],
    ),
    local_timestamp_ns: index,
    kind: types.Stop("complete"),
    evidence: types.Exact,
  )
}

fn batch(mode: String, event_count: Int) -> String {
  let events = case event_count {
    0 -> []
    _ ->
      int.range(from: 1, to: event_count + 1, with: [], run: fn(items, index) {
        [event(index), ..items]
      })
      |> list.reverse
  }
  "{\"type\":\"batch\",\"mode\":\""
  <> mode
  <> "\",\"privacy\":\"metadata\",\"items\":["
  <> { events |> list.map(codec.encode_event) |> string.join(",") }
  <> "]}"
}

pub fn durable_commit_precedes_live_inbox_visibility_test() {
  let assert Ok(metadata) = team_store.open(":memory:")
  let inbox = relay_inbox.new(max_frames: 4, max_bytes: 1024)
  let blobs = "build/beamtrace-relay-ingest-blobs-v2"
  let relay_id = "relay-1234567890abcdef12345678"
  let payload = batch("exact", 0)

  relay_ingest.accept(
    metadata,
    blobs,
    inbox,
    relay_id,
    1,
    relay_inbox.Exact,
    payload,
    3000,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.snapshot(inbox, relay_id)
  |> should.equal([relay_inbox.Payload(1, payload, 3000)])

  // The immutable blob rejects a conflicting replay before inbox publication.
  relay_ingest.accept(
    metadata,
    blobs,
    inbox,
    relay_id,
    1,
    relay_inbox.Exact,
    batch("exact", 1),
    3001,
  )
  |> should.equal(Error("blob_conflict"))
  relay_inbox.snapshot(inbox, relay_id)
  |> should.equal([relay_inbox.Payload(1, payload, 3000)])

  relay_inbox.close(inbox)
  team_store.close(metadata) |> should.equal(Ok(Nil))
}

pub fn durable_quota_rejects_before_blob_or_inbox_publication_test() {
  let assert Ok(metadata) = team_store.open(":memory:")
  let inbox = relay_inbox.new(max_frames: 4, max_bytes: 1024)
  let blobs = "build/beamtrace-relay-quota-blobs-v2"
  let relay_id = "relay-876543210fedcba987654321"
  let policy = relay_ingest.Quota(max_events: 2, max_bytes: 1_000_000)
  let first = batch("live", 2)
  let second = batch("live", 1)

  relay_ingest.accept_with_quota(
    metadata,
    blobs,
    inbox,
    relay_id,
    1,
    relay_inbox.Live,
    first,
    4000,
    policy,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_ingest.accept_with_quota(
    metadata,
    blobs,
    inbox,
    relay_id,
    2,
    relay_inbox.Live,
    second,
    4001,
    policy,
  )
  |> should.equal(Error("relay_event_quota"))

  team_store.relay_usage(metadata, relay_id)
  |> should.equal(Ok(#(2, string.byte_size(first))))
  blob_store.read(blobs, "relays/relay-876543210fedcba987654321/frames/2.json")
  |> should.equal(Error("blob_not_found"))
  relay_inbox.snapshot(inbox, relay_id)
  |> should.equal([relay_inbox.Payload(1, first, 4000)])

  relay_inbox.close(inbox)
  team_store.close(metadata) |> should.equal(Ok(Nil))
}

import beamtrace/codec
import beamtrace/types
