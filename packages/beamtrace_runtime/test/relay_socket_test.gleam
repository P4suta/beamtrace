// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_inbox
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
    local_timestamp_ns: 100,
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
  let assert relay_socket.Active(_, 0, 1004) = authenticated.state
  let assert [relay_socket.SendText(credit)] = authenticated.effects
  credit |> string.contains("\"type\":\"credit\"") |> should.be_true()

  let first =
    relay_wire.sign_envelope(
      identity,
      1,
      "{\"type\":\"batch\",\"mode\":\"exact\",\"items\":[]}",
    )
    |> relay_wire.encode_envelope
  let accepted = relay_socket.receive_text(authenticated.state, first, 1005)
  let assert relay_socket.Active(_, 1, 1005) = accepted.state
  accepted.effects
  |> should.equal([
    relay_socket.Payload(
      relay.id,
      1,
      relay_inbox.Exact,
      "{\"type\":\"batch\",\"mode\":\"exact\",\"items\":[]}",
    ),
  ])

  let replayed = relay_socket.receive_text(accepted.state, first, 1006)
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
  let assert relay_socket.Active(_, 1, 1005) = alive.state
  alive.effects |> should.equal([])

  let unknown =
    relay_wire.sign_envelope(identity, 2, "{\"type\":\"shell\"}")
    |> relay_wire.encode_envelope
  relay_socket.receive_text(alive.state, unknown, 1006).state
  |> should.equal(relay_socket.Rejected("invalid_payload"))
  enrollment_store.close(store)
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
  let frame =
    relay_wire.sign_envelope(
      identity,
      1,
      "{\"type\":\"batch\",\"mode\":\"exact\",\"privacy\":\"metadata\",\"items\":["
        <> unsafe_event
        <> "]}",
    )
    |> relay_wire.encode_envelope

  let rejected = relay_socket.receive_text(authenticated.state, frame, 1005)
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
