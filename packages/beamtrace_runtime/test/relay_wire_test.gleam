// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_wire
import gleam/bit_array
import gleam/string
import gleeunit/should

fn nonce() -> BitArray {
  bit_array.base16_decode("00112233445566778899aabbccddeeff")
  |> should.be_ok()
}

pub fn signed_hello_authenticates_an_enrolled_relay_exactly_once_test() {
  let identity = relay_channel.new_identity()
  let #(store, code) = enrollment_store.new_at(1000, 1000)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, identity.public_key, 1001)
  let hello = relay_wire.prepare_hello(identity, relay.id, 1010, nonce())

  let encoded = relay_wire.encode_hello(hello)
  encoded |> string.contains(relay.id) |> should.be_true()
  encoded
  |> string.contains(bit_array.base64_url_encode(identity.private_key, False))
  |> should.be_false()
  let assert Ok(decoded) = relay_wire.decode_hello(encoded)
  decoded |> should.equal(hello)

  relay_wire.authenticate(store, decoded, 1011)
  |> should.equal(Ok(relay))
  relay_wire.authenticate(store, decoded, 1012)
  |> should.equal(Error("replayed_nonce"))
  enrollment_store.close(store)
}

pub fn hello_rejects_stale_tampered_unknown_and_oversized_frames_test() {
  let identity = relay_channel.new_identity()
  let #(store, code) = enrollment_store.new_at(1000, 1000)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, identity.public_key, 1001)
  let hello = relay_wire.prepare_hello(identity, relay.id, 1000, nonce())

  relay_wire.authenticate(store, hello, 31_001)
  |> should.equal(Error("stale_hello"))
  relay_wire.authenticate(
    store,
    relay_wire.Hello(..hello, timestamp_ms: 1001),
    1002,
  )
  |> should.equal(Error("invalid_signature"))
  relay_wire.authenticate(
    store,
    relay_wire.Hello(..hello, relay_id: "relay-unknown"),
    1002,
  )
  |> should.equal(Error("unknown_relay"))
  relay_wire.decode_hello(string.repeat("x", 16_385))
  |> should.equal(Error("frame_too_large"))
  relay_wire.decode_hello("{\"protocol_version\":2}")
  |> should.equal(Error("invalid_hello"))
  enrollment_store.close(store)
}

pub fn signed_envelopes_are_bounded_tamper_evident_and_strictly_ordered_test() {
  let identity = relay_channel.new_identity()
  let envelope = relay_wire.sign_envelope(identity, 1, "{\"events\":[]}")
  let encoded = relay_wire.encode_envelope(envelope)
  encoded
  |> string.contains(bit_array.base64_url_encode(identity.private_key, False))
  |> should.be_false()
  relay_wire.decode_envelope(encoded) |> should.equal(Ok(envelope))
  relay_wire.verify_envelope(identity.public_key, envelope, 0)
  |> should.equal(Ok("{\"events\":[]}"))
  relay_wire.verify_envelope(identity.public_key, envelope, 1)
  |> should.equal(Error("invalid_sequence"))
  relay_wire.verify_envelope(
    identity.public_key,
    relay_wire.Envelope(..envelope, payload: "tampered"),
    0,
  )
  |> should.equal(Error("invalid_signature"))

  relay_wire.sign_envelope(identity, 2, string.repeat("x", 1_048_577))
  |> fn(oversized) {
    relay_wire.verify_envelope(identity.public_key, oversized, 1)
  }
  |> should.equal(Error("frame_too_large"))

  relay_wire.decode_envelope("{\"protocol_version\":2}")
  |> should.equal(Error("invalid_envelope"))
  relay_wire.decode_envelope(string.repeat("x", 1_114_113))
  |> should.equal(Error("frame_too_large"))
}

pub fn version_one_clients_receive_an_explicit_upgrade_error_test() {
  relay_wire.decode_hello(
    "{\"type\":\"hello\",\"protocol_version\":1,\"relay_id\":\"relay-old\",\"timestamp_ms\":0,\"nonce\":\"\",\"signature\":\"\"}",
  )
  |> should.equal(Error("upgrade_required"))
  relay_wire.decode_envelope(
    "{\"type\":\"message\",\"protocol_version\":1,\"sequence\":1,\"payload\":\"{}\",\"signature\":\"\"}",
  )
  |> should.equal(Error("upgrade_required"))
}
