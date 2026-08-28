import beamtrace/codec
import beamtrace/types
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
