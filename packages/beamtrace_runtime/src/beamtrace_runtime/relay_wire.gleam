// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/relay_channel
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/string

const protocol_version = 1

const max_hello_bytes = 16_384

const max_envelope_bytes = 1_048_576

const max_encoded_envelope_bytes = 1_114_112

pub type Hello {
  Hello(
    protocol_version: Int,
    relay_id: String,
    timestamp_ms: Int,
    nonce: BitArray,
    signature: BitArray,
  )
}

pub type Envelope {
  Envelope(sequence: Int, payload: String, signature: BitArray)
}

type EncodedHello {
  EncodedHello(
    protocol_version: Int,
    relay_id: String,
    timestamp_ms: Int,
    nonce: String,
    signature: String,
  )
}

type EncodedEnvelope {
  EncodedEnvelope(
    protocol_version: Int,
    sequence: Int,
    payload: String,
    signature: String,
  )
}

pub fn prepare_hello(
  identity: relay_channel.Identity,
  relay_id: String,
  timestamp_ms: Int,
  nonce: BitArray,
) -> Hello {
  Hello(
    protocol_version: protocol_version,
    relay_id: relay_id,
    timestamp_ms: timestamp_ms,
    nonce: nonce,
    signature: relay_channel.sign(
      identity,
      hello_payload(relay_id, timestamp_ms, nonce),
    ),
  )
}

pub fn encode_hello(hello: Hello) -> String {
  json.object([
    #("type", json.string("hello")),
    #("protocol_version", json.int(hello.protocol_version)),
    #("relay_id", json.string(hello.relay_id)),
    #("timestamp_ms", json.int(hello.timestamp_ms)),
    #("nonce", json.string(bit_array.base64_url_encode(hello.nonce, False))),
    #(
      "signature",
      json.string(bit_array.base64_url_encode(hello.signature, False)),
    ),
  ])
  |> json.to_string
}

pub fn decode_hello(source: String) -> Result(Hello, String) {
  case string.byte_size(source) > max_hello_bytes {
    True -> Error("frame_too_large")
    False ->
      case json.parse(source, hello_decoder()) {
        Error(_) -> Error("invalid_hello")
        Ok(encoded) -> decode_hello_parts(encoded)
      }
  }
}

pub fn authenticate(
  store: enrollment_store.Store,
  hello: Hello,
  now_ms: Int,
) -> Result(enrollment_store.RelayRecord, String) {
  case hello.protocol_version == protocol_version {
    False -> Error("unsupported_protocol")
    True ->
      enrollment_store.authenticate(
        store,
        hello.relay_id,
        hello.timestamp_ms,
        hello.nonce,
        hello.signature,
        now_ms,
      )
  }
}

pub fn sign_envelope(
  identity: relay_channel.Identity,
  sequence: Int,
  payload: String,
) -> Envelope {
  Envelope(
    sequence: sequence,
    payload: payload,
    signature: relay_channel.sign(identity, envelope_payload(sequence, payload)),
  )
}

pub fn encode_envelope(envelope: Envelope) -> String {
  json.object([
    #("type", json.string("batch")),
    #("protocol_version", json.int(protocol_version)),
    #("sequence", json.int(envelope.sequence)),
    #("payload", json.string(envelope.payload)),
    #(
      "signature",
      json.string(bit_array.base64_url_encode(envelope.signature, False)),
    ),
  ])
  |> json.to_string
}

pub fn decode_envelope(source: String) -> Result(Envelope, String) {
  case string.byte_size(source) > max_encoded_envelope_bytes {
    True -> Error("frame_too_large")
    False ->
      case json.parse(source, envelope_decoder()) {
        Error(_) -> Error("invalid_envelope")
        Ok(encoded) ->
          case
            encoded.protocol_version == protocol_version,
            encoded.sequence > 0,
            string.byte_size(encoded.payload) <= max_envelope_bytes,
            bit_array.base64_url_decode(encoded.signature)
          {
            True, True, True, Ok(signature) ->
              case bit_array.byte_size(signature) == 64 {
                True ->
                  Ok(Envelope(encoded.sequence, encoded.payload, signature))
                False -> Error("invalid_envelope")
              }
            _, _, _, _ -> Error("invalid_envelope")
          }
      }
  }
}

pub fn verify_envelope(
  public_key: BitArray,
  envelope: Envelope,
  previous_sequence: Int,
) -> Result(String, String) {
  case
    string.byte_size(envelope.payload) > max_envelope_bytes,
    envelope.sequence == previous_sequence + 1,
    relay_channel.verify(
      public_key,
      envelope_payload(envelope.sequence, envelope.payload),
      envelope.signature,
    )
  {
    True, _, _ -> Error("frame_too_large")
    _, False, _ -> Error("invalid_sequence")
    _, _, False -> Error("invalid_signature")
    False, True, True -> Ok(envelope.payload)
  }
}

fn decode_hello_parts(encoded: EncodedHello) -> Result(Hello, String) {
  case
    encoded.protocol_version == protocol_version,
    encoded.relay_id != "" && string.byte_size(encoded.relay_id) <= 128,
    bit_array.base64_url_decode(encoded.nonce),
    bit_array.base64_url_decode(encoded.signature)
  {
    True, True, Ok(nonce), Ok(signature) ->
      case
        bit_array.byte_size(nonce) >= 16
        && bit_array.byte_size(nonce) <= 64
        && bit_array.byte_size(signature) == 64
      {
        True ->
          Ok(Hello(
            encoded.protocol_version,
            encoded.relay_id,
            encoded.timestamp_ms,
            nonce,
            signature,
          ))
        False -> Error("invalid_hello")
      }
    _, _, _, _ -> Error("invalid_hello")
  }
}

fn hello_decoder() -> decode.Decoder(EncodedHello) {
  use type_ <- decode.field("type", decode.string)
  use version <- decode.field("protocol_version", decode.int)
  use relay_id <- decode.field("relay_id", decode.string)
  use timestamp <- decode.field("timestamp_ms", decode.int)
  use nonce <- decode.field("nonce", decode.string)
  use signature <- decode.field("signature", decode.string)
  case type_ == "hello" {
    True ->
      decode.success(EncodedHello(
        version,
        relay_id,
        timestamp,
        nonce,
        signature,
      ))
    False ->
      decode.failure(
        EncodedHello(version, relay_id, timestamp, nonce, signature),
        expected: "hello frame",
      )
  }
}

fn envelope_decoder() -> decode.Decoder(EncodedEnvelope) {
  use type_ <- decode.field("type", decode.string)
  use version <- decode.field("protocol_version", decode.int)
  use sequence <- decode.field("sequence", decode.int)
  use payload <- decode.field("payload", decode.string)
  use signature <- decode.field("signature", decode.string)
  case type_ == "batch" {
    True ->
      decode.success(EncodedEnvelope(version, sequence, payload, signature))
    False ->
      decode.failure(
        EncodedEnvelope(version, sequence, payload, signature),
        expected: "batch frame",
      )
  }
}

fn hello_payload(
  relay_id: String,
  timestamp_ms: Int,
  nonce: BitArray,
) -> BitArray {
  let source =
    "beamtrace-relay-v1\nhello\n"
    <> relay_id
    <> "\n"
    <> int.to_string(timestamp_ms)
    <> "\n"
    <> bit_array.base64_url_encode(nonce, False)
  bit_array.from_string(source)
}

fn envelope_payload(sequence: Int, payload: String) -> BitArray {
  let source =
    "beamtrace-relay-v1\nbatch\n" <> int.to_string(sequence) <> "\n" <> payload
  bit_array.from_string(source)
}
