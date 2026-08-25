import beamtrace/codec
import beamtrace/types
import gleam/option.{Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn canonical_event_round_trip_test() {
  let process =
    types.ProcessIdentity(
      physical: types.ProcessRef("app@host", "<0.42.0>"),
      logical: Some(types.LogicalActor("worker/checkout", "checkout")),
      evidence: [types.ProcessLabel("checkout")],
    )
  let event =
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

  event
  |> codec.encode_event
  |> codec.decode_event
  |> should.equal(Ok(event))
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
