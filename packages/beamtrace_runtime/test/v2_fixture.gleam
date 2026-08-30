// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/dag
import beamtrace/types
import beamtrace_runtime/capture
import beamtrace_runtime/storage

pub const public_jwks = "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"key-1\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"AQ\",\"e\":\"Aw\"}]}"

pub fn instant(value: Int) -> types.LocalInstant {
  types.LocalInstant(value, value)
}

pub fn serial(current: Int) -> types.SequenceSerial {
  types.SequenceSerial(current - 1, current)
}

pub fn verified_outcome() -> types.CaptureOutcome {
  verified_outcome_for("fixture@host")
}

fn verified_outcome_for(node: String) -> types.CaptureOutcome {
  types.CaptureOutcome(end: types.QuietPeriod(250), issues: [], receipts: [
    types.NodeReceipt(node, 1, 1, 1),
  ])
}

pub fn capture_result(events: List(types.TraceEvent)) -> capture.CaptureResult {
  let assert [node, ..] = event_nodes(events)
  capture.CaptureResult(
    events,
    verified_outcome_for(node),
    types.empty_calibration(),
  )
}

pub fn manifest(capture_id: String, nodes: List(String)) -> codec.Manifest {
  let receipt_node = case nodes {
    [node, ..] -> node
    [] -> "fixture@host"
  }
  codec.Manifest(
    schema_version: 2,
    tool_version: "0.3.0",
    capture_id: capture_id,
    nodes: nodes,
    outcome: verified_outcome_for(receipt_node),
    privacy: types.Metadata,
  )
}

pub fn archive(events: List(types.TraceEvent)) -> storage.Archive {
  let assert Ok(graph) = dag.build(events)
  storage.Archive(
    manifest("fixture-capture", event_nodes(events)),
    events,
    graph,
    types.empty_calibration(),
  )
}

fn event_nodes(events: List(types.TraceEvent)) -> List(String) {
  case events {
    [] -> ["fixture@host"]
    [first, ..] -> [first.node]
  }
}
