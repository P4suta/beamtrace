import beamtrace/types
import beamtrace_runtime/storage
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import v2_fixture

fn fixture_event() {
  let process =
    types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", "<0.1.0>"),
      logical: None,
      evidence: [],
    )
  types.TraceEvent(
    id: "event-1",
    root_id: "root-1",
    node: "fixture@host",
    process: process,
    local_instant: v2_fixture.instant(10),
    kind: types.Stop("complete"),
    evidence: types.Exact,
  )
}

fn fixture_manifest() {
  v2_fixture.manifest("capture-storage-test", ["fixture@host"])
}

pub fn agtrace_is_versioned_zip_and_round_trips_test() {
  let path = "build/beamtrace-storage-test.beamtrace"
  storage.save(path, fixture_manifest(), [fixture_event()])
  |> should.equal(Ok(Nil))

  let assert Ok(archive) = storage.load(path)
  archive.manifest |> should.equal(fixture_manifest())
  archive.events |> should.equal([fixture_event()])

  let assert Ok(entries) = storage.entries(path)
  entries
  |> list.sort(fn(a, b) { string.compare(a, b) })
  |> should.equal([
    "annotations.json",
    "checksums.json",
    "clocks.json",
    "events/000001.ndjson",
    "graph/000001.json",
    "indexes/events.idx",
    "manifest.json",
  ])
}

pub fn non_zip_and_missing_manifest_are_rejected_test() {
  storage.load("gleam.toml")
  |> should.equal(Error(storage.InvalidContainer))
}

pub fn save_rejects_event_nodes_not_declared_by_manifest_test() {
  let invalid = v2_fixture.manifest("invalid-node-reference", ["other@host"])
  storage.save("build/beamtrace-invalid-write.beamtrace", invalid, [
    fixture_event(),
  ])
  |> should.equal(
    Error(storage.CodecError(
      "InvalidField(\"events.node\", \"references a node not declared by the manifest\")",
    )),
  )
}

pub fn large_trace_is_segmented_and_loaded_in_event_order_test() {
  let path = "build/beamtrace-segmented-test.beamtrace"
  let events =
    int.range(from: 1, to: 1002, with: [], run: fn(events, index) {
      [
        types.TraceEvent(
          ..fixture_event(),
          id: "event-" <> int.to_string(index),
          local_instant: v2_fixture.instant(index),
        ),
        ..events
      ]
    })
    |> list.reverse

  storage.save(path, fixture_manifest(), events) |> should.equal(Ok(Nil))
  let assert Ok(entries) = storage.entries(path)
  entries
  |> list.filter(fn(path) { string.starts_with(path, "events/") })
  |> list.length
  |> should.equal(2)

  let assert Ok(archive) = storage.load(path)
  archive.events |> list.length |> should.equal(1001)
  let assert [first, ..] = archive.events
  first.id |> should.equal("event-1")
}

pub fn event_window_reads_across_segments_without_loading_the_archive_test() {
  let path = "build/beamtrace-windowed-test.beamtrace"
  let events =
    int.range(from: 1, to: 1002, with: [], run: fn(events, index) {
      [
        types.TraceEvent(
          ..fixture_event(),
          id: "event-" <> int.to_string(index),
          local_instant: v2_fixture.instant(index),
        ),
        ..events
      ]
    })
    |> list.reverse
  storage.save(path, fixture_manifest(), events) |> should.equal(Ok(Nil))

  let assert Ok(window) = storage.window(path, start: 999, limit: 2)
  window.total |> should.equal(1001)
  window.start |> should.equal(999)
  window.events
  |> list.map(fn(event) { event.id })
  |> should.equal(["event-1000", "event-1001"])
}

pub fn event_window_rejects_unbounded_or_negative_requests_test() {
  storage.window("unused.beamtrace", start: -1, limit: 10)
  |> should.equal(Error(storage.InvalidWindow))
  storage.window("unused.beamtrace", start: 0, limit: 0)
  |> should.equal(Error(storage.InvalidWindow))
  storage.window("unused.beamtrace", start: 0, limit: 1001)
  |> should.equal(Error(storage.InvalidWindow))
}

pub fn full_text_search_scans_segments_but_only_materializes_the_window_test() {
  let path = "build/beamtrace-search-test.beamtrace"
  let events =
    int.range(from: 1, to: 1002, with: [], run: fn(events, index) {
      let kind = case index == 500 || index == 1001 {
        True -> types.Stop("NeedleAcrossSegments")
        False -> types.Stop("complete")
      }
      [
        types.TraceEvent(
          ..fixture_event(),
          id: "event-" <> int.to_string(index),
          local_instant: v2_fixture.instant(index),
          kind: kind,
        ),
        ..events
      ]
    })
    |> list.reverse
  storage.save(path, fixture_manifest(), events) |> should.equal(Ok(Nil))

  let assert Ok(window) =
    storage.search(path, "needleacrosssegments", start: 1, limit: 1)
  window.total |> should.equal(2)
  window.start |> should.equal(1)
  window.events
  |> list.map(fn(event) { event.id })
  |> should.equal(["event-1001"])
}

pub fn full_text_search_rejects_empty_or_unbounded_queries_test() {
  storage.search("unused.beamtrace", "", start: 0, limit: 10)
  |> should.equal(Error(storage.InvalidSearch))
  storage.search(
    "unused.beamtrace",
    string.repeat("x", 257),
    start: 0,
    limit: 10,
  )
  |> should.equal(Error(storage.InvalidSearch))
  storage.search("unused.beamtrace", "valid", start: -1, limit: 10)
  |> should.equal(Error(storage.InvalidWindow))
}
