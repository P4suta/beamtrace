// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/protocol
import beamtrace/types
import gleeunit/should

pub fn otp_message_protocols_are_classified_semantically_test() {
  protocol.classify(
    types.Tuple([
      types.Atom("$gen_call"),
      types.Hidden,
      types.Tag("get"),
    ]),
  )
  |> should.equal(protocol.Call)

  protocol.classify(
    types.Tuple([
      types.Atom("$gen_cast"),
      types.Tag("refresh"),
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
  protocol.classify(types.Tuple([types.Tag("domain_event"), types.Hidden]))
  |> should.equal(protocol.Ordinary)
}
