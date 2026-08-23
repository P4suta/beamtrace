// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/local_auth
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_payload
import beamtrace_runtime/relay_wire
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri

pub type EnrollmentRequest {
  EnrollmentRequest(url: String, body: String)
}

pub type EnrollmentReceipt {
  EnrollmentReceipt(relay_id: String, channel_url: String)
}

pub type Websocket

pub type RelayClientError {
  InsecureHubUrl
  InvalidHubUrl
  InvalidEnrollmentToken
  TransportError(reason: String)
  InvalidResponse(reason: String)
}

pub type ChannelState {
  AwaitingCredit(sequence: Int)
  Active(sequence: Int, credits: Int, max_batch_events: Int)
  Stopped(reason: String)
}

type BatchEncoding {
  MetadataEncoding
  RawEncoding(grant: String, policy: types.RawPolicy)
}

type CreditControl {
  CreditControl(protocol_version: Int, credits: Int, max_batch_events: Int)
}

type StopControl {
  StopControl(completeness: String, reason: String)
}

const max_control_frame_bytes = 16_384

const max_credits = 1_000_000

const max_batch_events = 128

pub fn prepare_enrollment(
  hub_url: String,
  token: String,
  identity: relay_channel.Identity,
) -> Result(EnrollmentRequest, RelayClientError) {
  use base <- result_try(validate_hub_url(hub_url))
  case string.trim(token) == "" {
    True -> Error(InvalidEnrollmentToken)
    False -> {
      let body =
        json.object([
          #("protocol_version", json.int(relay_channel.protocol_version)),
          #("token", json.string(token)),
          #("algorithm", json.string("Ed25519")),
          #(
            "public_key",
            json.string(bit_array.base64_url_encode(identity.public_key, False)),
          ),
        ])
        |> json.to_string
      Ok(EnrollmentRequest(base <> "/api/relay/v1/enroll", body))
    }
  }
}

pub fn enroll(
  hub_url: String,
  token: String,
  identity: relay_channel.Identity,
) -> Result(EnrollmentReceipt, RelayClientError) {
  use request <- result_try(prepare_enrollment(hub_url, token, identity))
  case post_json(request.url, request.body) {
    Error(reason) -> Error(TransportError(reason))
    Ok(response) -> {
      let #(status, body) = response
      case status == 200 || status == 201 {
        True -> decode_receipt(body)
        False ->
          Error(TransportError("hub returned HTTP " <> int_to_string(status)))
      }
    }
  }
}

/// Keep the relay's outbound-only authenticated channel alive until the hub
/// stops it or the verified TLS connection fails.
pub fn run_channel(
  receipt: EnrollmentReceipt,
  identity: relay_channel.Identity,
) -> Result(Nil, String) {
  let hello =
    relay_wire.prepare_hello(
      identity,
      receipt.relay_id,
      local_auth.now_ms(),
      websocket_nonce(),
    )
    |> relay_wire.encode_hello
  case websocket_connect(receipt.channel_url, hello) {
    Error(reason) -> Error(reason)
    Ok(socket) -> {
      let outcome = wait_for_credit(socket, initial_channel_state(), identity)
      websocket_close(socket)
      outcome
    }
  }
}

/// Transfer a completed bounded target capture over the authenticated
/// outbound-only channel. One batch is kept in flight at a time and the next
/// batch is not sent until the hub replenishes credit after durable ingest.
pub fn run_channel_with_events(
  receipt: EnrollmentReceipt,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
) -> Result(Nil, String) {
  let hello =
    relay_wire.prepare_hello(
      identity,
      receipt.relay_id,
      local_auth.now_ms(),
      websocket_nonce(),
    )
    |> relay_wire.encode_hello
  case websocket_connect(receipt.channel_url, hello) {
    Error(reason) -> Error(reason)
    Ok(socket) -> {
      let outcome = case await_initial_credit(socket) {
        Error(reason) -> Error(reason)
        Ok(state) ->
          produce_events(
            socket,
            state,
            identity,
            mode,
            events,
            MetadataEncoding,
          )
      }
      websocket_close(socket)
      outcome
    }
  }
}

pub fn run_channel_with_raw_events(
  receipt: EnrollmentReceipt,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  grant: String,
  policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> Result(Nil, String) {
  let hello =
    relay_wire.prepare_hello(
      identity,
      receipt.relay_id,
      local_auth.now_ms(),
      websocket_nonce(),
    )
    |> relay_wire.encode_hello
  case websocket_connect(receipt.channel_url, hello) {
    Error(reason) -> Error(reason)
    Ok(socket) -> {
      let outcome = case await_initial_credit(socket) {
        Error(reason) -> Error(reason)
        Ok(state) ->
          produce_events(
            socket,
            state,
            identity,
            mode,
            events,
            RawEncoding(grant, policy),
          )
      }
      websocket_close(socket)
      outcome
    }
  }
}

fn await_initial_credit(socket: Websocket) -> Result(ChannelState, String) {
  case websocket_receive(socket, 10_000) {
    Error("timeout") -> Error("credit_timeout")
    Error(reason) -> Error(reason)
    Ok(frame) ->
      case receive_control(initial_channel_state(), frame) {
        Error(reason) -> Error(reason)
        Ok(Stopped(reason)) -> Error("hub_stopped:" <> reason)
        Ok(AwaitingCredit(_)) -> await_initial_credit(socket)
        Ok(active) -> Ok(active)
      }
  }
}

fn produce_events(
  socket: Websocket,
  state: ChannelState,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
) -> Result(Nil, String) {
  case events, state {
    [], _ -> Ok(Nil)
    _, Stopped(reason) -> Error("hub_stopped:" <> reason)
    _, AwaitingCredit(_) -> Error("awaiting_credit")
    _, Active(_, credits, _) if credits <= 0 ->
      case await_credit(socket, state, identity) {
        Error(reason) -> Error(reason)
        Ok(next) ->
          produce_events(socket, next, identity, mode, events, encoding)
      }
    _, Active(_, _, _) -> {
      case next_encoded_event_prefix(state, identity, mode, events, encoding) {
        Error(reason) -> Error(reason)
        Ok(#(frame, sent_state, remaining)) ->
          case websocket_send(socket, frame) {
            Error(reason) -> Error(reason)
            Ok(Nil) ->
              case await_credit(socket, sent_state, identity) {
                Error(reason) -> Error(reason)
                Ok(acknowledged) ->
                  produce_events(
                    socket,
                    acknowledged,
                    identity,
                    mode,
                    remaining,
                    encoding,
                  )
              }
          }
      }
    }
  }
}

fn await_credit(
  socket: Websocket,
  state: ChannelState,
  identity: relay_channel.Identity,
) -> Result(ChannelState, String) {
  let before = channel_credits(state)
  case websocket_receive(socket, 10_000) {
    Error("timeout") ->
      case next_heartbeat(state, identity) {
        Error(reason) -> Error(reason)
        Ok(#(frame, heartbeat_state)) ->
          case websocket_send(socket, frame) {
            Error(reason) -> Error(reason)
            Ok(Nil) -> await_credit(socket, heartbeat_state, identity)
          }
      }
    Error(reason) -> Error(reason)
    Ok(frame) ->
      case receive_control(state, frame) {
        Error(reason) -> Error(reason)
        Ok(Stopped(reason)) -> Error("hub_stopped:" <> reason)
        Ok(next) ->
          case channel_credits(next) > before {
            True -> Ok(next)
            False -> await_credit(socket, next, identity)
          }
      }
  }
}

fn channel_credits(state: ChannelState) -> Int {
  case state {
    Active(_, credits, _) -> credits
    AwaitingCredit(_) | Stopped(_) -> 0
  }
}

pub fn decode_receipt(
  source: String,
) -> Result(EnrollmentReceipt, RelayClientError) {
  case json.parse(source, receipt_decoder()) {
    Error(_) -> Error(InvalidResponse("malformed enrollment response"))
    Ok(receipt) ->
      case
        valid_relay_id(receipt.relay_id),
        valid_channel_url(receipt.channel_url)
      {
        True, True -> Ok(receipt)
        False, _ -> Error(InvalidResponse("invalid relay_id"))
        _, False -> Error(InvalidResponse("channel_url must use wss"))
      }
  }
}

fn wait_for_credit(
  socket: Websocket,
  state: ChannelState,
  identity: relay_channel.Identity,
) -> Result(Nil, String) {
  case websocket_receive(socket, 10_000) {
    Error("timeout") -> Error("credit_timeout")
    Error(reason) -> Error(reason)
    Ok(frame) ->
      case receive_control(state, frame) {
        Error(reason) -> Error(reason)
        Ok(Stopped(reason)) -> Error("hub_stopped:" <> reason)
        Ok(AwaitingCredit(sequence)) ->
          wait_for_credit(socket, AwaitingCredit(sequence), identity)
        Ok(Active(sequence, credits, max_batch_events)) ->
          channel_loop(
            socket,
            Active(sequence, credits, max_batch_events),
            identity,
          )
      }
  }
}

fn channel_loop(
  socket: Websocket,
  state: ChannelState,
  identity: relay_channel.Identity,
) -> Result(Nil, String) {
  case websocket_receive(socket, 10_000) {
    Error("timeout") ->
      case next_heartbeat(state, identity) {
        Error(reason) -> Error(reason)
        Ok(#(frame, next)) ->
          case websocket_send(socket, frame) {
            Ok(Nil) -> channel_loop(socket, next, identity)
            Error(reason) -> Error(reason)
          }
      }
    Error(reason) -> Error(reason)
    Ok(frame) ->
      case receive_control(state, frame) {
        Error(reason) -> Error(reason)
        Ok(Stopped(reason)) -> Error("hub_stopped:" <> reason)
        Ok(next) -> channel_loop(socket, next, identity)
      }
  }
}

pub fn initial_channel_state() -> ChannelState {
  AwaitingCredit(0)
}

pub fn receive_control(
  state: ChannelState,
  source: String,
) -> Result(ChannelState, String) {
  case string.byte_size(source) > max_control_frame_bytes {
    True -> Error("control_frame_too_large")
    False ->
      case json.parse(source, control_type_decoder()) {
        Ok("credit") -> receive_credit(state, source)
        Ok("stop") -> receive_stop(source)
        _ -> Error("invalid_control")
      }
  }
}

pub fn next_heartbeat(
  state: ChannelState,
  identity: relay_channel.Identity,
) -> Result(#(String, ChannelState), String) {
  case state {
    AwaitingCredit(_) -> Error("awaiting_credit")
    Stopped(_) -> Error("channel_stopped")
    Active(sequence, credits, max_batch_events) -> {
      let next_sequence = sequence + 1
      let frame =
        relay_wire.sign_envelope(
          identity,
          next_sequence,
          "{\"type\":\"heartbeat\"}",
        )
        |> relay_wire.encode_envelope
      Ok(#(frame, Active(next_sequence, credits, max_batch_events)))
    }
  }
}

pub fn next_event_batch(
  state: ChannelState,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
) -> Result(#(String, ChannelState), String) {
  next_encoded_event_batch(state, identity, mode, events, MetadataEncoding)
}

pub fn next_raw_event_batch(
  state: ChannelState,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  grant: String,
  policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> Result(#(String, ChannelState), String) {
  next_encoded_event_batch(
    state,
    identity,
    mode,
    events,
    RawEncoding(grant, policy),
  )
}

/// Encode the largest bounded prefix that fits one signed transport frame.
/// Remaining events are returned unchanged for the next credit cycle.
pub fn next_raw_event_prefix(
  state: ChannelState,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  grant: String,
  policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> Result(#(String, ChannelState, List(types.TraceEvent)), String) {
  next_encoded_event_prefix(
    state,
    identity,
    mode,
    events,
    RawEncoding(grant, policy),
  )
}

fn next_encoded_event_prefix(
  state: ChannelState,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
) -> Result(#(String, ChannelState, List(types.TraceEvent)), String) {
  case state {
    Active(_, _, limit) ->
      fit_encoded_event_prefix(
        state,
        identity,
        mode,
        events,
        encoding,
        int.min(list.length(events), limit),
      )
    AwaitingCredit(_) -> Error("awaiting_credit")
    Stopped(_) -> Error("channel_stopped")
  }
}

fn fit_encoded_event_prefix(
  state: ChannelState,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
  count: Int,
) -> Result(#(String, ChannelState, List(types.TraceEvent)), String) {
  let batch = list.take(events, count)
  case next_encoded_event_batch(state, identity, mode, batch, encoding) {
    Ok(#(frame, next)) -> Ok(#(frame, next, list.drop(events, count)))
    Error("frame_too_large") if count > 1 -> {
      let next_count = case int.divide(count, by: 2) {
        Ok(value) -> int.max(value, 1)
        Error(_) -> 1
      }
      fit_encoded_event_prefix(
        state,
        identity,
        mode,
        events,
        encoding,
        next_count,
      )
    }
    Error(reason) -> Error(reason)
  }
}

fn next_encoded_event_batch(
  state: ChannelState,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
) -> Result(#(String, ChannelState), String) {
  let event_count = list.length(events)
  case state {
    AwaitingCredit(_) -> Error("awaiting_credit")
    Stopped(_) -> Error("channel_stopped")
    Active(_, credits, _) if credits <= 0 -> Error("credit_exhausted")
    Active(sequence, credits, limit) -> {
      case event_count == 0, event_count > limit {
        True, _ -> Error("empty_batch")
        _, True -> Error("batch_event_limit")
        False, False -> {
          let mode_name = case mode {
            relay_channel.Exact -> "exact"
            relay_channel.Live -> "live"
          }
          let encoded = case encoding {
            MetadataEncoding -> relay_payload.encode(mode_name, events)
            RawEncoding(grant, policy) ->
              relay_payload.encode_raw(mode_name, grant, policy, events)
          }
          case encoded {
            Error(error) -> Error(error)
            Ok(payload) -> {
              case string.byte_size(payload) > relay_wire.max_envelope_bytes {
                True -> Error("frame_too_large")
                False -> {
                  let next_sequence = sequence + 1
                  let frame =
                    relay_wire.sign_envelope(identity, next_sequence, payload)
                    |> relay_wire.encode_envelope
                  case
                    string.byte_size(frame)
                    > relay_wire.max_encoded_envelope_bytes
                  {
                    True -> Error("frame_too_large")
                    False ->
                      Ok(#(frame, Active(next_sequence, credits - 1, limit)))
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn receive_credit(
  state: ChannelState,
  source: String,
) -> Result(ChannelState, String) {
  case json.parse(source, credit_decoder()) {
    Error(_) -> Error("invalid_control")
    Ok(credit) ->
      case
        credit.protocol_version == relay_channel.protocol_version,
        credit.credits > 0 && credit.credits <= max_credits,
        credit.max_batch_events > 0
        && credit.max_batch_events <= max_batch_events,
        state
      {
        True, True, True, AwaitingCredit(sequence) ->
          Ok(Active(sequence, credit.credits, credit.max_batch_events))
        True, True, True, Active(sequence, existing, _) ->
          case existing + credit.credits <= max_credits {
            True ->
              Ok(Active(
                sequence,
                existing + credit.credits,
                credit.max_batch_events,
              ))
            False -> Error("invalid_control")
          }
        _, _, _, _ -> Error("invalid_control")
      }
  }
}

fn receive_stop(source: String) -> Result(ChannelState, String) {
  case json.parse(source, stop_decoder()) {
    Ok(stop) if stop.completeness != "" && stop.reason != "" ->
      Ok(Stopped(stop.completeness <> ":" <> stop.reason))
    _ -> Error("invalid_control")
  }
}

fn control_type_decoder() -> decode.Decoder(String) {
  use type_ <- decode.field("type", decode.string)
  decode.success(type_)
}

fn credit_decoder() -> decode.Decoder(CreditControl) {
  use protocol_version <- decode.field("protocol_version", decode.int)
  use credits <- decode.field("credits", decode.int)
  use max_batch_events <- decode.field("max_batch_events", decode.int)
  decode.success(CreditControl(protocol_version, credits, max_batch_events))
}

fn stop_decoder() -> decode.Decoder(StopControl) {
  use completeness <- decode.field("completeness", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(StopControl(completeness, reason))
}

fn receipt_decoder() -> decode.Decoder(EnrollmentReceipt) {
  use relay_id <- decode.field("relay_id", decode.string)
  use channel_url <- decode.field("channel_url", decode.string)
  decode.success(EnrollmentReceipt(relay_id, channel_url))
}

fn validate_hub_url(source: String) -> Result(String, RelayClientError) {
  case uri.parse(source) {
    Error(_) -> Error(InvalidHubUrl)
    Ok(parsed) ->
      case
        parsed.scheme,
        parsed.host,
        parsed.userinfo,
        parsed.query,
        parsed.fragment
      {
        Some("http"), Some(_), None, None, None -> Error(InsecureHubUrl)
        Some("https"), Some(host), None, None, None if host != "" ->
          Ok(trim_trailing_slashes(source))
        _, _, _, _, _ -> Error(InvalidHubUrl)
      }
  }
}

fn valid_channel_url(source: String) -> Bool {
  case uri.parse(source) {
    Ok(parsed) ->
      case
        parsed.scheme,
        parsed.host,
        parsed.userinfo,
        parsed.query,
        parsed.fragment
      {
        Some("wss"), Some(host), None, None, None -> host != ""
        _, _, _, _, _ -> False
      }
    Error(_) -> False
  }
}

fn valid_relay_id(relay_id: String) -> Bool {
  case string.starts_with(relay_id, "relay-") {
    False -> False
    True ->
      case bit_array.base16_decode(string.drop_start(relay_id, 6)) {
        Ok(bytes) -> bit_array.byte_size(bytes) == 12
        Error(_) -> False
      }
  }
}

fn trim_trailing_slashes(source: String) -> String {
  case string.ends_with(source, "/") {
    True -> trim_trailing_slashes(string.drop_end(source, 1))
    False -> source
  }
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(value: Int) -> String

@external(erlang, "beamtrace_relay_http_ffi", "post_json")
fn post_json(url: String, body: String) -> Result(#(Int, String), String)

@external(erlang, "beamtrace_websocket_client_ffi", "connect")
fn websocket_connect(url: String, hello: String) -> Result(Websocket, String)

@external(erlang, "beamtrace_websocket_client_ffi", "send_text")
fn websocket_send(socket: Websocket, frame: String) -> Result(Nil, String)

@external(erlang, "beamtrace_websocket_client_ffi", "receive_text")
fn websocket_receive(
  socket: Websocket,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "beamtrace_websocket_client_ffi", "close")
fn websocket_close(socket: Websocket) -> Nil

@external(erlang, "beamtrace_websocket_client_ffi", "nonce")
fn websocket_nonce() -> BitArray
