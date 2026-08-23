// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_payload
import beamtrace_runtime/relay_wire
import gleam/dynamic/decode
import gleam/json

const hello_timeout_ms = 10_000

const heartbeat_timeout_ms = 30_000

pub type State {
  AwaitingHello(
    store: enrollment_store.Store,
    expected_relay_id: String,
    connected_at_ms: Int,
  )
  Active(
    relay: enrollment_store.RelayRecord,
    last_sequence: Int,
    last_heartbeat_ms: Int,
  )
  Rejected(reason: String)
}

pub type Effect {
  SendText(frame: String)
  Payload(
    relay_id: String,
    sequence: Int,
    mode: relay_inbox.Mode,
    payload: String,
  )
  Close(reason: String)
}

pub type Transition {
  Transition(state: State, effects: List(Effect))
}

type PayloadKind {
  Heartbeat
  Batch(mode: relay_inbox.Mode)
}

pub fn new(
  store: enrollment_store.Store,
  expected_relay_id: String,
  now_ms: Int,
) -> State {
  AwaitingHello(store, expected_relay_id, now_ms)
}

pub fn receive_text(state: State, frame: String, now_ms: Int) -> Transition {
  case state {
    AwaitingHello(store, expected_relay_id, _) ->
      receive_hello(store, expected_relay_id, frame, now_ms)
    Active(relay, previous_sequence, _) ->
      receive_envelope(relay, previous_sequence, frame, now_ms)
    Rejected(reason) -> Transition(state, [Close(reason)])
  }
}

pub fn expire(state: State, now_ms: Int) -> State {
  case state {
    AwaitingHello(_, _, connected_at)
      if now_ms - connected_at > hello_timeout_ms
    -> Rejected("hello_timeout")
    Active(_, _, last_heartbeat)
      if now_ms - last_heartbeat > heartbeat_timeout_ms
    -> Rejected("heartbeat_timeout")
    _ -> state
  }
}

fn receive_hello(
  store: enrollment_store.Store,
  expected_relay_id: String,
  frame: String,
  now_ms: Int,
) -> Transition {
  case relay_wire.decode_hello(frame) {
    Error(reason) -> reject(reason)
    Ok(hello) ->
      case hello.relay_id == expected_relay_id {
        False -> reject("relay_id_mismatch")
        True ->
          case relay_wire.authenticate(store, hello, now_ms) {
            Error(reason) -> reject(reason)
            Ok(relay) ->
              Transition(Active(relay, 0, now_ms), [SendText(credit_frame())])
          }
      }
  }
}

fn receive_envelope(
  relay: enrollment_store.RelayRecord,
  previous_sequence: Int,
  frame: String,
  now_ms: Int,
) -> Transition {
  case relay_wire.decode_envelope(frame) {
    Error(reason) -> reject(reason)
    Ok(envelope) ->
      case
        relay_wire.verify_envelope(
          relay.public_key,
          envelope,
          previous_sequence,
        )
      {
        Error(reason) -> reject(reason)
        Ok(payload) ->
          case payload_kind(payload) {
            Error(reason) -> reject(reason)
            Ok(Heartbeat) ->
              Transition(Active(relay, envelope.sequence, now_ms), [])
            Ok(Batch(mode)) ->
              Transition(Active(relay, envelope.sequence, now_ms), [
                Payload(relay.id, envelope.sequence, mode, payload),
              ])
          }
      }
  }
}

fn reject(reason: String) -> Transition {
  Transition(Rejected(reason), [Close(reason)])
}

fn credit_frame() -> String {
  "{\"type\":\"credit\",\"protocol_version\":1,\"credits\":8,\"max_batch_events\":128}"
}

fn payload_kind(source: String) -> Result(PayloadKind, String) {
  case json.parse(source, payload_type_decoder()) {
    Ok("heartbeat") -> Ok(Heartbeat)
    Ok("batch") ->
      case relay_payload.decode(source) {
        Ok(batch) ->
          case batch.mode {
            "exact" -> Ok(Batch(relay_inbox.Exact))
            "live" -> Ok(Batch(relay_inbox.Live))
            _ -> Error("invalid_payload")
          }
        Error(reason) -> Error(reason)
      }
    _ -> Error("invalid_payload")
  }
}

fn payload_type_decoder() -> decode.Decoder(String) {
  use value <- decode.field("type", decode.string)
  decode.success(value)
}
