//// Tune diagnostic thresholds through the facade instead of hand-wiring
//// each analysis.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace
import beamtrace/diagnostics
import beamtrace/event
import beamtrace/types
import gleam/int
import gleam/io
import gleam/list

pub fn main() {
  let worker = event.process(node: "app@host", pid: "<0.10.0>")
  let builder = event.builder(root: "root-1", process: worker)
  let events =
    list.map([1, 2, 3], fn(index) {
      builder
      |> event.at(offset_ns: index * 100, order: index)
      |> event.send(
        id: "send-" <> int.to_string(index),
        to: types.ProcessRef("app@host", "<0.20.0>"),
        message: types.TagOnly("work"),
        serial: event.serial(previous: index - 1, current: index),
      )
    })

  let assert Ok(trace) = beamtrace.from_events(events)
  let default_count = list.length(beamtrace.findings(trace))
  let tuned =
    beamtrace.findings_with(
      trace,
      thresholds: diagnostics.Thresholds(
        ..diagnostics.default_thresholds(),
        hot_sender_messages: 3,
      ),
    )
  io.println(
    "default="
    <> int.to_string(default_count)
    <> " tuned="
    <> int.to_string(list.length(tuned)),
  )
}
