//// Construct codec-valid events with beamtrace/event and round-trip them
//// through the canonical codec.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/event
import beamtrace/types
import gleam/io

pub fn main() {
  let worker = event.process(node: "app@host", pid: "<0.10.0>")
  let sent =
    event.builder(root: "job-1", process: worker)
    |> event.at(offset_ns: 250, order: 1)
    |> event.send(
      id: "send-1",
      to: types.ProcessRef("app@host", "<0.20.0>"),
      message: types.Tuple([types.TagOnly("work"), types.Hidden]),
      serial: event.serial(previous: 0, current: 1),
    )

  let assert Ok(Nil) = codec.validate_event(sent)
  let assert Ok(decoded) = codec.decode_event(codec.encode_event(sent))
  io.println(case decoded == sent {
    True -> "validated=true roundtrip=ok"
    False -> "roundtrip=broken"
  })
}
