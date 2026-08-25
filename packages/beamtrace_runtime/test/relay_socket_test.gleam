// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_session
import beamtrace_runtime/relay_socket
import beamtrace_runtime/relay_wire
import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn nonce() -> BitArray {
  bit_array.base16_decode("11223344556677889900aabbccddeeff")
  |> should.be_ok()
}

fn event_with(term: types.TermView) -> String {
  codec.encode_event(types.TraceEvent(
    id: "event-1",
    root_id: "root-1",
    node: "fixture@host",
    process: types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", "<0.1.0>"),
      logical: None,
      evidence: [],
    ),
    local_instant: types.LocalInstant(100, 1),
    kind: types.Exit(term),
    evidence: types.Exact,
  ))
}

pub fn socket_requires_hello_then_accepts_strictly_ordered_signed_batches_test() {
  let identity = relay_channel.new_identity()
  let #(store, code) = enrollment_store.new_at(1000, 1000)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, identity.public_key, 1001)
  let initial = relay_socket.new(store, relay.id, 1002)
  let hello =
    relay_wire.prepare_hello(identity, relay.id, 1003, nonce())
    |> relay_wire.encode_hello

  let authenticated = relay_socket.receive_text(initial, hello, 1004)
  let assert relay_socket.Active(_, 3, 0, 1004, 8, None) = authenticated.state
  let assert [relay_socket.SendText(credit)] = authenticated.effects
  credit |> string.contains("\"type\":\"credit\"") |> should.be_true()

  let start = session_start(relay.id)
  let opened = send_session_start(authenticated.state, identity, start, 1, 1005)
  let assert relay_socket.Active(
    _,
    3,
    1,
    1005,
    8,
    Some(relay_socket.SessionState(saved_start, 0)),
  ) = opened.state
  saved_start |> should.equal(start)
  opened.effects |> should.equal([relay_socket.SessionStarted(start)])

  let payload = safe_payload()
  let first =
    relay_wire.sign_envelope(
      identity,
      2,
      relay_session.encode_batch(start.session_id, 1, payload),
    )
    |> relay_wire.encode_envelope
  let accepted = relay_socket.receive_text(opened.state, first, 1006)
  let assert relay_socket.Active(
    _,
    3,
    2,
    1006,
    7,
    Some(relay_socket.SessionState(_, 1)),
  ) = accepted.state
  accepted.effects
  |> should.equal([
    relay_socket.Payload(
      start.session_id,
      relay.id,
      1,
      relay_inbox.Exact,
      payload,
    ),
  ])

  let replayed = relay_socket.receive_text(accepted.state, first, 1007)
  replayed.state
  |> should.equal(relay_socket.Rejected("invalid_sequence"))
  replayed.effects
  |> should.equal([relay_socket.Close("invalid_sequence")])
  enrollment_store.close(store)
}

pub fn socket_accepts_signed_heartbeats_but_rejects_unknown_payload_types_test() {
  let identity = relay_channel.new_identity()
  let #(store, code) = enrollment_store.new_at(1000, 1000)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, identity.public_key, 1001)
  let authenticated =
    relay_socket.receive_text(
      relay_socket.new(store, relay.id, 1002),
      relay_wire.prepare_hello(identity, relay.id, 1003, nonce())
        |> relay_wire.encode_hello,
      1004,
    )
  let heartbeat =
    relay_wire.sign_envelope(identity, 1, "{\"type\":\"heartbeat\"}")
    |> relay_wire.encode_envelope
  let alive = relay_socket.receive_text(authenticated.state, heartbeat, 1005)
  let assert relay_socket.Active(_, 3, 1, 1005, 8, None) = alive.state
  alive.effects |> should.equal([])

  let unknown =
    relay_wire.sign_envelope(identity, 2, "{\"type\":\"shell\"}")
    |> relay_wire.encode_envelope
  relay_socket.receive_text(alive.state, unknown, 1006).state
  |> should.equal(relay_socket.Rejected("invalid_session_message"))
  enrollment_store.close(store)
}

pub fn durable_credit_refills_only_when_the_four_batch_boundary_is_crossed_test() {
  let identity = relay_channel.new_identity()
  let #(store, code) = enrollment_store.new_at(1000, 1000)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, identity.public_key, 1001)
  let authenticated =
    relay_socket.receive_text(
      relay_socket.new(store, relay.id, 1002),
      relay_wire.prepare_hello(identity, relay.id, 1003, nonce())
        |> relay_wire.encode_hello,
      1004,
    )

  let start = session_start(relay.id)
  let opened = send_session_start(authenticated.state, identity, start, 1, 1005)
  let #(one, one_credit) = durable_batch(opened.state, identity, 2)
  one_credit |> should.equal(None)
  let #(two, two_credit) = durable_batch(one, identity, 3)
  two_credit |> should.equal(None)
  let #(three, three_credit) = durable_batch(two, identity, 4)
  three_credit |> should.equal(None)
  let #(four, four_credit) = durable_batch(three, identity, 5)
  four_credit
  |> should.equal(Some(
    "{\"type\":\"credit\",\"protocol_version\":3,\"credits\":4,\"max_batch_events\":128}",
  ))
  let assert relay_socket.Active(
    _,
    3,
    5,
    _,
    8,
    Some(relay_socket.SessionState(_, 4)),
  ) = four
  enrollment_store.close(store)
}

pub fn session_sequence_is_contiguous_and_resets_for_the_next_session_test() {
  let identity = relay_channel.new_identity()
  let #(store, code) = enrollment_store.new_at(1000, 1000)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, identity.public_key, 1001)
  let authenticated =
    relay_socket.receive_text(
      relay_socket.new(store, relay.id, 1002),
      relay_wire.prepare_hello(identity, relay.id, 1003, nonce())
        |> relay_wire.encode_hello,
      1004,
    )
  let start = session_start(relay.id)
  let opened = send_session_start(authenticated.state, identity, start, 1, 1005)

  let skipped =
    relay_wire.sign_envelope(
      identity,
      2,
      relay_session.encode_batch(start.session_id, 2, safe_payload()),
    )
    |> relay_wire.encode_envelope
    |> fn(frame) { relay_socket.receive_text(opened.state, frame, 1006) }
  skipped.state
  |> should.equal(relay_socket.Rejected("invalid_session_sequence"))

  let first =
    relay_wire.sign_envelope(
      identity,
      2,
      relay_session.encode_batch(start.session_id, 1, safe_payload()),
    )
    |> relay_wire.encode_envelope
    |> fn(frame) { relay_socket.receive_text(opened.state, frame, 1006) }
  let ended =
    relay_wire.sign_envelope(
      identity,
      3,
      relay_session.encode_end(relay_session.End(
        session_id: start.session_id,
        sequence: 2,
        ended_at_ms: 1010,
        delivery_status: relay_session.Delivered,
      )),
    )
    |> relay_wire.encode_envelope
    |> fn(frame) { relay_socket.receive_text(first.state, frame, 1011) }
  let assert relay_socket.Active(_, 3, 3, _, _, None) = ended.state

  let second_start =
    relay_session.Start(
      ..start,
      session_id: "ffeeddccbbaa99887766554433221100",
      started_at_ms: 1012,
    )
  let second = send_session_start(ended.state, identity, second_start, 4, 1012)
  let assert relay_socket.Active(
    _,
    3,
    4,
    _,
    _,
    Some(relay_socket.SessionState(_, 0)),
  ) = second.state
  enrollment_store.close(store)
}

fn durable_batch(
  state: relay_socket.State,
  identity: relay_channel.Identity,
  sequence: Int,
) {
  let frame =
    relay_wire.sign_envelope(
      identity,
      sequence,
      relay_session.encode_batch(session_id(), sequence - 1, safe_payload()),
    )
    |> relay_wire.encode_envelope
  let transition = relay_socket.receive_text(state, frame, 1004 + sequence)
  relay_socket.durable_accept(transition.state)
}

pub fn socket_rejects_metadata_values_before_emitting_a_storage_effect_test() {
  let identity = relay_channel.new_identity()
  let #(store, code) = enrollment_store.new_at(1000, 1000)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, identity.public_key, 1001)
  let authenticated =
    relay_socket.receive_text(
      relay_socket.new(store, relay.id, 1002),
      relay_wire.prepare_hello(identity, relay.id, 1003, nonce())
        |> relay_wire.encode_hello,
      1004,
    )
  let unsafe_event =
    event_with(types.Scalar(
      "string",
      Some("SENTINEL-secret-never-store"),
      Some(string.repeat("a", 64)),
    ))
  let start = session_start(relay.id)
  let opened = send_session_start(authenticated.state, identity, start, 1, 1005)
  let unsafe_payload =
    "{\"type\":\"batch\",\"mode\":\"exact\",\"privacy\":\"metadata\",\"items\":["
    <> unsafe_event
    <> "]}"
  let frame =
    relay_wire.sign_envelope(
      identity,
      2,
      relay_session.encode_batch(start.session_id, 1, unsafe_payload),
    )
    |> relay_wire.encode_envelope

  let rejected = relay_socket.receive_text(opened.state, frame, 1006)
  rejected.state
  |> should.equal(relay_socket.Rejected("metadata_value_forbidden"))
  rejected.effects
  |> should.equal([relay_socket.Close("metadata_value_forbidden")])
  enrollment_store.close(store)
}

pub fn socket_rejects_path_identity_mismatch_and_expires_heartbeats_test() {
  let identity = relay_channel.new_identity()
  let #(store, code) = enrollment_store.new_at(1000, 1000)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, identity.public_key, 1001)
  let hello = relay_wire.prepare_hello(identity, relay.id, 1003, nonce())

  relay_socket.receive_text(
    relay_socket.new(store, "relay-other", 1002),
    relay_wire.encode_hello(hello),
    1004,
  )
  |> fn(transition) {
    transition.state |> should.equal(relay_socket.Rejected("relay_id_mismatch"))
  }

  relay_socket.expire(relay_socket.new(store, relay.id, 1000), 11_001)
  |> should.equal(relay_socket.Rejected("hello_timeout"))
  let authenticated =
    relay_socket.receive_text(
      relay_socket.new(store, relay.id, 1002),
      relay_wire.encode_hello(hello),
      1004,
    )
  relay_socket.expire(authenticated.state, 31_005)
  |> should.equal(relay_socket.Rejected("heartbeat_timeout"))
  enrollment_store.close(store)
}

import beamtrace/codec
import beamtrace/types

fn session_id() -> String {
  "00112233445566778899aabbccddeeff"
}

fn session_start(relay_id: String) -> relay_session.Start {
  relay_session.Start(
    session_id: session_id(),
    relay_id: relay_id,
    node: "fixture@host",
    module_: "shop",
    function_: "checkout",
    arity: 1,
    mode: relay_session.Exact,
    privacy: relay_session.Metadata,
    started_at_ms: 1000,
  )
}

fn safe_payload() -> String {
  "{\"type\":\"batch\",\"mode\":\"exact\",\"privacy\":\"metadata\",\"items\":["
  <> event_with(types.Hidden)
  <> "]}"
}

fn send_session_start(
  state: relay_socket.State,
  identity: relay_channel.Identity,
  start: relay_session.Start,
  sequence: Int,
  now_ms: Int,
) -> relay_socket.Transition {
  relay_wire.sign_envelope(
    identity,
    sequence,
    relay_session.encode_start(start),
  )
  |> relay_wire.encode_envelope
  |> fn(frame) { relay_socket.receive_text(state, frame, now_ms) }
}
