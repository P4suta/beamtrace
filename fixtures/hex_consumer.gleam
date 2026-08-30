// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace
import beamtrace/codec
import beamtrace/diagnostics
import beamtrace/mfa
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
  let assert Ok(trace) = beamtrace.decode_events([encoded])
  let graph = beamtrace.graph(trace)
  let report = beamtrace.compare(trace, trace)
  let assert Ok(parsed_mfa) = mfa.parse("shop:checkout/1")
  let assert [finding] =
    diagnostics.hot_senders(beamtrace.events(trace), minimum_messages: 1)
  let assert diagnostics.CountValue(message_count) = finding.value

  io.println(
    "facade=checked dag_boundaries="
    <> { graph.boundaries |> list.length |> int.to_string }
    <> " diagnostic_messages="
    <> int.to_string(message_count)
    <> " diff_changed="
    <> int.to_string(report.changed)
    <> " mfa="
    <> mfa.to_string(parsed_mfa),
  )
}
