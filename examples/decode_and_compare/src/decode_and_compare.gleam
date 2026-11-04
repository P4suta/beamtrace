//// Build two runs with the event builder, decode them through the validated
//// facade, and compare their causal shape.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace
import beamtrace/codec
import beamtrace/event
import beamtrace/types
import gleam/int
import gleam/io
import gleam/list
import gleam/result

fn run_lines(label: String) -> List(String) {
  let checkout =
    event.actor(
      node: "shop@localhost",
      pid: "<0.10.0>",
      id: "checkout",
      label: "checkout",
    )
  let builder = event.builder(root: label <> "-root", process: checkout)
  [
    builder
      |> event.at(offset_ns: 0, order: 0)
      |> event.root(
        id: label <> "-root",
        trigger: types.Mfa("shop", "checkout", 1),
        arguments: [types.TagOnly("order")],
      ),
    builder
      |> event.at(offset_ns: 120, order: 1)
      |> event.send(
        id: label <> "-send",
        to: types.ProcessRef("shop@localhost", "<0.20.0>"),
        message: types.TagOnly("charge"),
        serial: event.serial(previous: 0, current: 1),
      ),
  ]
  |> list.map(codec.encode_event)
}

pub fn main() {
  let summary = {
    use baseline <- result.try(beamtrace.decode_events(run_lines("a")))
    use candidate <- result.try(beamtrace.decode_events(run_lines("b")))
    let report = beamtrace.compare(baseline, candidate)
    Ok(
      "changed="
      <> int.to_string(report.changed)
      <> " added="
      <> int.to_string(report.added)
      <> " events="
      <> int.to_string(beamtrace.event_count(candidate)),
    )
  }
  case summary {
    Ok(line) -> io.println(line)
    Error(failure) -> io.println(beamtrace.error_message(failure))
  }
}
