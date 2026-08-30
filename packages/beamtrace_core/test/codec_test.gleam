import beamtrace/codec
import beamtrace/types
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn canonical_event_round_trip_test() {
  let event = sample_event()

  event
  |> codec.encode_event
  |> codec.decode_event
  |> should.equal(Ok(event))
}

fn sample_event() -> types.TraceEvent {
  let process =
    types.ProcessIdentity(
      physical: types.ProcessRef("app@host", "<0.42.0>"),
      logical: Some(types.LogicalActor("worker/checkout", "checkout")),
      evidence: [types.ProcessLabel("checkout")],
    )
  types.TraceEvent(
    id: "evt-1",
    root_id: "root-1",
    node: "app@host",
    process: process,
    local_instant: types.LocalInstant(123, 4),
    kind: types.Send(
      types.ProcessRef("app@host", "<0.43.0>"),
      types.Constructor("$gen_call", [types.Hidden]),
      types.SequenceSerial(6, 7),
    ),
    evidence: types.Exact,
  )
}

pub fn manifest_records_budget_outcome_test() {
  let manifest =
    codec.Manifest(
      schema_version: 2,
      tool_version: "0.3.0",
      capture_id: "capture-1",
      nodes: ["app@host"],
      outcome: types.CaptureOutcome(
        end: types.BudgetReached("bytes"),
        issues: [types.DroppedEvents("app@host", 2)],
        receipts: [types.NodeReceipt("app@host", 3, 20, 4096)],
      ),
      privacy: types.Metadata,
    )

  let encoded = codec.encode_manifest(manifest)
  encoded |> string.contains("\"kind\":\"budget_reached\"") |> should.be_true()
  encoded |> string.contains("\"kind\":\"dropped_events\"") |> should.be_true()
  codec.decode_manifest(encoded) |> should.equal(Ok(manifest))
}

pub fn typed_validators_match_codec_boundaries_without_json_round_trip_test() {
  let event =
    types.TraceEvent(
      id: "evt-direct",
      root_id: "root-direct",
      node: "app@host",
      process: types.ProcessIdentity(
        physical: types.ProcessRef("app@host", "<0.42.0>"),
        logical: None,
        evidence: [],
      ),
      local_instant: types.LocalInstant(1, 1),
      kind: types.Stop("complete"),
      evidence: types.Exact,
    )
  let manifest =
    codec.Manifest(
      schema_version: 2,
      tool_version: "0.3.0",
      capture_id: "capture-direct",
      nodes: ["app@host"],
      outcome: types.CaptureOutcome(types.QuietPeriod(250), [], [
        types.NodeReceipt("app@host", 1, 1, 1),
      ]),
      privacy: types.Metadata,
    )
  let segment = codec.GraphSegment([event.id], [], [])

  codec.validate_manifest(manifest) |> should.equal(Ok(Nil))
  codec.validate_event(event) |> should.equal(Ok(Nil))
  codec.validate_graph_segment(segment) |> should.equal(Ok(Nil))
  codec.validate_clocks(types.empty_calibration()) |> should.equal(Ok(Nil))

  codec.validate_event(
    types.TraceEvent(..event, local_instant: types.LocalInstant(-1, 1)),
  )
  |> should.equal(
    Error(codec.InvalidField(
      "local_instant.offset_ns",
      "must be a non-negative JavaScript-safe relative value",
    )),
  )
}

pub fn graph_segments_validate_local_and_cross_segment_references_test() {
  codec.validate_graph_segment(
    codec.GraphSegment(
      ["event-1"],
      [types.CausalEdge("event-1", "event-2", types.ProcessOrder, types.Exact)],
      [],
    ),
  )
  |> should.equal(Ok(Nil))

  let dangling_edge =
    codec.GraphSegment(
      ["event-1"],
      [
        types.CausalEdge(
          "missing-1",
          "missing-2",
          types.ProcessOrder,
          types.Exact,
        ),
      ],
      [],
    )
  dangling_edge
  |> codec.encode_graph_segment
  |> codec.decode_graph_segment
  |> should.equal(
    Error(codec.InvalidField("graph.edge", "invalid edge reference")),
  )

  codec.validate_graph_segment(
    codec.GraphSegment(["event-1"], [], [
      types.Boundary("missing", types.ExternalBoundary, "outside capture"),
    ]),
  )
  |> should.equal(
    Error(codec.InvalidField("graph.boundary", "invalid boundary")),
  )
}

pub fn versioned_event_decode_preserves_legacy_and_canonical_rules_test() {
  let event = sample_event()
  let canonical = codec.encode_event(event)
  let with_unknown_field = string.drop_end(canonical, 1) <> ",\"unknown\":true}"
  let legacy =
    "{\"schema_version\":1,\"id\":\"legacy\",\"root_id\":\"root\",\"node\":\"app@host\",\"process\":{\"physical\":{\"node\":\"app@host\",\"pid\":\"<0.1.0>\"},\"logical\":null,\"identity_evidence\":[]},\"local_timestamp_ns\":42,\"event\":{\"kind\":\"stop\",\"value\":\"done\"},\"evidence\":{\"kind\":\"exact\"}}"

  codec.decode_event(" " <> canonical)
  |> should.equal(Error(codec.NonCanonicalJson))
  codec.decode_event(with_unknown_field)
  |> should.equal(Error(codec.NonCanonicalJson))
  codec.decode_event_structural(with_unknown_field)
  |> should.equal(Ok(event))
  codec.decode_event("{\"schema_version\":99}")
  |> should.equal(Error(codec.UnknownSchemaVersion(99)))
  codec.decode_event(legacy)
  |> should.equal(
    Ok(types.TraceEvent(
      id: "legacy",
      root_id: "root",
      node: "app@host",
      process: types.ProcessIdentity(
        physical: types.ProcessRef("app@host", "<0.1.0>"),
        logical: None,
        evidence: [],
      ),
      local_instant: types.LocalInstant(42, 0),
      kind: types.Stop("done"),
      evidence: types.Exact,
    )),
  )
}

pub fn codec_error_messages_are_stable_across_targets_test() {
  codec.error_message(codec.InvalidJson("x")) |> should.equal("invalid JSON")
  codec.error_message(codec.UnknownSchemaVersion(7))
  |> should.equal("unsupported schema version 7")
  codec.error_message(codec.NonCanonicalJson)
  |> should.equal("JSON is not canonical")
  codec.error_message(codec.InvalidField("id", "invalid event id"))
  |> should.equal("invalid field 'id': invalid event id")
}

fn sample_clocks() -> types.ClockCalibration {
  types.ClockCalibration(1, [
    types.NodeClock(
      "app@host",
      1000,
      Some(types.ClockSample(1000, 5000, 40, 80)),
      Some(types.ClockSample(2000, 6000, 40, 80)),
    ),
  ])
}

pub fn structured_json_builders_match_canonical_string_encoders_test() {
  let event = sample_event()
  json.to_string(codec.event_json(event))
  |> should.equal(codec.encode_event(event))
  let clocks = sample_clocks()
  json.to_string(codec.clocks_json(clocks))
  |> should.equal(codec.encode_clocks(clocks))
}

pub fn clocks_round_trip_and_reject_non_canonical_bytes_test() {
  let clocks = sample_clocks()
  let encoded = codec.encode_clocks(clocks)
  codec.decode_clocks(encoded) |> should.equal(Ok(clocks))
  codec.decode_clocks(" " <> encoded) |> should.be_error()
}

pub fn schema_version_constant_is_emitted_by_every_encoder_test() {
  codec.schema_version |> should.equal(2)
  let manifest =
    codec.Manifest(
      schema_version: 1,
      tool_version: "0.3.0",
      capture_id: "capture-1",
      nodes: ["app@host"],
      outcome: types.CaptureOutcome(types.QuietPeriod(250), [], []),
      privacy: types.Metadata,
    )
  [
    codec.encode_event(sample_event()),
    codec.encode_manifest(manifest),
    codec.encode_clocks(sample_clocks()),
  ]
  |> list.each(fn(encoded) {
    encoded |> string.contains("\"schema_version\":2") |> should.be_true()
  })
}
