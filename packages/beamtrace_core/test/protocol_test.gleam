// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/protocol
import beamtrace/types
import gleeunit/should

pub fn otp_message_protocols_are_classified_semantically_test() {
  protocol.classify(
    types.Tuple([
      types.Atom("$gen_call"),
      types.Hidden,
      types.TagOnly("get"),
    ]),
  )
  |> should.equal(protocol.Call)

  protocol.classify(
    types.Tuple([
      types.Atom("$gen_cast"),
      types.TagOnly("refresh"),
    ]),
  )
  |> should.equal(protocol.Cast)

  protocol.classify(
    types.Tuple([
      types.Atom("DOWN"),
      types.Hidden,
      types.Atom("process"),
      types.Hidden,
      types.Atom("normal"),
    ]),
  )
  |> should.equal(protocol.MonitorDown)

  protocol.classify(types.Atom("timeout")) |> should.equal(protocol.Timeout)
}

pub fn unknown_shape_remains_ordinary_instead_of_inventing_semantics_test() {
  protocol.classify(types.Tuple([types.TagOnly("domain_event"), types.Hidden]))
  |> should.equal(protocol.Ordinary)
}

pub fn labels_are_stable_display_strings_test() {
  protocol.label(types.Constructor("$gen_call", [])) |> should.equal("call")
  protocol.label(types.Constructor("$gen_cast", [])) |> should.equal("cast")
  protocol.label(types.Constructor("$gen_reply", [])) |> should.equal("reply")
  protocol.label(
    types.Tuple([
      types.Atom("DOWN"),
      types.Hidden,
      types.Atom("process"),
      types.Hidden,
      types.Atom("normal"),
    ]),
  )
  |> should.equal("DOWN")
  protocol.label(types.Tuple([types.Atom("EXIT"), types.Hidden, types.Hidden]))
  |> should.equal("EXIT")
  protocol.label(types.Atom("timeout")) |> should.equal("timeout")
  protocol.label(types.Constructor("spawn_request", []))
  |> should.equal("spawn")
  protocol.label(types.TagOnly("domain_event")) |> should.equal("message")
}
