// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/dag
import beamtrace/diagnostics
import beamtrace/types
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}

pub fn main() {
  let sender =
    types.ProcessIdentity(
      physical: types.ProcessRef("shop@localhost", "<0.10.0>"),
      logical: None,
      evidence: [],
    )
  let event =
    types.TraceEvent(
      id: "send-1",
      root_id: "checkout-1",
      node: "shop@localhost",
      process: sender,
      local_instant: types.LocalInstant(offset_ns: 100, order: 1),
      kind: types.Send(
        to: types.ProcessRef("shop@localhost", "<0.20.0>"),
        message: types.Tag("charge"),
        serial: types.SequenceSerial(previous: 0, current: 1),
      ),
      evidence: types.Exact,
    )

  let encoded = codec.encode_event(event)
  let assert Ok(decoded) = codec.decode_event(encoded)
  let assert Ok(graph) = dag.build([decoded])
  let assert [finding] = diagnostics.hot_senders([decoded], minimum_messages: 1)
  let assert diagnostics.CountValue(message_count) = finding.value

  io.println(
    "codec=round-trip dag_boundaries="
    <> { graph.boundaries |> list.length |> int.to_string }
    <> " diagnostic_messages="
    <> int.to_string(message_count),
  )
}
