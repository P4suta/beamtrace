// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/internal/version as runtime_version
import beamtrace_runtime/local_auth
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_payload
import beamtrace_runtime/relay_session
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

pub type TransferMetadata {
  TransferMetadata(
    node: String,
    module_: String,
    function_: String,
    arity: Int,
    delivery_status: relay_session.DeliveryStatus,
  )
}

type BatchEncoding {
  MetadataEncoding
  RawEncoding(grant: String, policy: types.RawPolicy)
}

type CreditControl {
  CreditControl(protocol_version: Int, credits: Int, max_batch_events: Int)
}

type StopControl {
  StopControl(delivery_status: String, reason: String)
}

type SessionAckControl {
  SessionAckControl(
    protocol_version: Int,
    session_id: String,
    sequence: Int,
    delivery_status: String,
  )
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
/// outbound-only channel. Batches consume the shared window and pause only
/// when all available credits have been spent.
pub fn run_channel_with_events(
  receipt: EnrollmentReceipt,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  metadata: TransferMetadata,
  events: List(types.TraceEvent),
) -> Result(Nil, String) {
  transfer_events(receipt, identity, mode, metadata, events, MetadataEncoding)
}

pub fn run_channel_with_raw_events(
  receipt: EnrollmentReceipt,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  metadata: TransferMetadata,
  grant: String,
  policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> Result(Nil, String) {
  transfer_events(
    receipt,
    identity,
    mode,
    metadata,
    events,
    RawEncoding(grant, policy),
  )
}

fn transfer_events(
  receipt: EnrollmentReceipt,
  identity: relay_channel.Identity,
  mode: relay_channel.Mode,
  metadata: TransferMetadata,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
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
        Ok(state) -> {
          let session_id = relay_session.new_id()
          let start =
            relay_session.Start(
              session_id: session_id,
              relay_id: receipt.relay_id,
              node: metadata.node,
              module_: metadata.module_,
              function_: metadata.function_,
              arity: metadata.arity,
              mode: session_mode(mode),
              privacy: encoding_privacy(encoding),
              started_at_ms: local_auth.now_ms(),
            )
          case next_session_start(state, identity, start) {
            Error(reason) -> Error(reason)
            Ok(#(start_frame, started)) ->
              case websocket_send(socket, start_frame) {
                Error(reason) -> Error(reason)
                Ok(Nil) ->
                  case
                    produce_events(
                      socket,
                      started,
                      identity,
                      session_id,
                      0,
                      mode,
                      events,
                      encoding,
                    )
                  {
                    Error(reason) -> Error(reason)
                    Ok(#(finished, last_session_sequence)) -> {
                      let end =
                        relay_session.End(
                          session_id: session_id,
                          sequence: last_session_sequence + 1,
                          ended_at_ms: local_auth.now_ms(),
                          delivery_status: metadata.delivery_status,
                        )
                      case next_session_end(finished, identity, end) {
                        Error(reason) -> Error(reason)
                        Ok(#(end_frame, ended_state)) ->
                          case websocket_send(socket, end_frame) {
                            Error(reason) -> Error(reason)
                            Ok(Nil) ->
                              await_session_ack(socket, ended_state, end)
                          }
                      }
                    }
                  }
              }
          }
        }
      }
      websocket_close(socket)
      outcome
    }
  }
}

fn await_session_ack(
  socket: Websocket,
  state: ChannelState,
  end: relay_session.End,
) -> Result(Nil, String) {
  case websocket_receive(socket, 10_000) {
    Error("timeout") -> Error("session_ack_timeout")
    Error(reason) -> Error(reason)
    Ok(frame) ->
      case receive_session_ack(frame, end) {
        Error(reason) -> Error(reason)
        Ok(True) -> Ok(Nil)
        Ok(False) ->
          case receive_control(state, frame) {
            Error(reason) -> Error(reason)
            Ok(Stopped(reason)) -> Error("hub_stopped:" <> reason)
            Ok(next) -> await_session_ack(socket, next, end)
          }
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
  session_id: String,
  session_sequence: Int,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
) -> Result(#(ChannelState, Int), String) {
  case events, state {
    [], _ -> Ok(#(state, session_sequence))
    _, Stopped(reason) -> Error("hub_stopped:" <> reason)
    _, AwaitingCredit(_) -> Error("awaiting_credit")
    _, Active(_, credits, _) if credits <= 0 ->
      case await_credit(socket, state, identity) {
        Error(reason) -> Error(reason)
        Ok(next) ->
          produce_events(
            socket,
            next,
            identity,
            session_id,
            session_sequence,
            mode,
            events,
            encoding,
          )
      }
    _, Active(_, _, _) -> {
      case
        next_encoded_event_prefix(
          state,
          identity,
          session_id,
          session_sequence + 1,
          mode,
          events,
          encoding,
        )
      {
        Error(reason) -> Error(reason)
        Ok(#(frame, sent_state, remaining)) ->
          case websocket_send(socket, frame) {
            Error(reason) -> Error(reason)
            Ok(Nil) ->
              produce_events(
                socket,
                sent_state,
                identity,
                session_id,
                session_sequence + 1,
                mode,
                remaining,
                encoding,
              )
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

pub fn receive_session_ack(
  source: String,
  expected: relay_session.End,
) -> Result(Bool, String) {
  let expected_delivery_status =
    relay_session.delivery_status_name(expected.delivery_status)
  case string.byte_size(source) > max_control_frame_bytes {
    True -> Error("control_frame_too_large")
    False ->
      case json.parse(source, control_type_decoder()) {
        Ok("session_ack") ->
          case json.parse(source, session_ack_decoder()) {
            Ok(ack)
              if ack.protocol_version == relay_channel.protocol_version
              && ack.session_id == expected.session_id
              && ack.sequence == expected.sequence
              && ack.delivery_status == expected_delivery_status
            -> Ok(True)
            _ -> Error("invalid_session_ack")
          }
        Ok(_) -> Ok(False)
        Error(_) -> Error("invalid_control")
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

pub fn next_session_start(
  state: ChannelState,
  identity: relay_channel.Identity,
  start: relay_session.Start,
) -> Result(#(String, ChannelState), String) {
  case state {
    AwaitingCredit(_) -> Error("awaiting_credit")
    Stopped(_) -> Error("channel_stopped")
    Active(sequence, credits, max_batch_events) -> {
      let payload = relay_session.encode_start(start)
      case relay_session.decode_message(payload) {
        Ok(relay_session.SessionStart(_)) -> {
          let next_sequence = sequence + 1
          let frame =
            relay_wire.sign_envelope(identity, next_sequence, payload)
            |> relay_wire.encode_envelope
          Ok(#(frame, Active(next_sequence, credits, max_batch_events)))
        }
        _ -> Error("invalid_session_start")
      }
    }
  }
}

pub fn next_session_end(
  state: ChannelState,
  identity: relay_channel.Identity,
  end: relay_session.End,
) -> Result(#(String, ChannelState), String) {
  case state {
    AwaitingCredit(_) -> Error("awaiting_credit")
    Stopped(_) -> Error("channel_stopped")
    Active(sequence, credits, max_batch_events) -> {
      let payload = relay_session.encode_end(end)
      case relay_session.decode_message(payload) {
        Ok(relay_session.SessionEnd(_)) -> {
          let next_sequence = sequence + 1
          let frame =
            relay_wire.sign_envelope(identity, next_sequence, payload)
            |> relay_wire.encode_envelope
          Ok(#(frame, Active(next_sequence, credits, max_batch_events)))
        }
        _ -> Error("invalid_session_end")
      }
    }
  }
}

pub fn next_event_batch(
  state: ChannelState,
  identity: relay_channel.Identity,
  session_id: String,
  session_sequence: Int,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
) -> Result(#(String, ChannelState), String) {
  next_encoded_event_batch(
    state,
    identity,
    session_id,
    session_sequence,
    mode,
    events,
    MetadataEncoding,
  )
}

pub fn next_raw_event_batch(
  state: ChannelState,
  identity: relay_channel.Identity,
  session_id: String,
  session_sequence: Int,
  mode: relay_channel.Mode,
  grant: String,
  policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> Result(#(String, ChannelState), String) {
  next_encoded_event_batch(
    state,
    identity,
    session_id,
    session_sequence,
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
  session_id: String,
  session_sequence: Int,
  mode: relay_channel.Mode,
  grant: String,
  policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> Result(#(String, ChannelState, List(types.TraceEvent)), String) {
  next_encoded_event_prefix(
    state,
    identity,
    session_id,
    session_sequence,
    mode,
    events,
    RawEncoding(grant, policy),
  )
}

fn next_encoded_event_prefix(
  state: ChannelState,
  identity: relay_channel.Identity,
  session_id: String,
  session_sequence: Int,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
) -> Result(#(String, ChannelState, List(types.TraceEvent)), String) {
  case state {
    Active(_, _, limit) ->
      fit_encoded_event_prefix(
        state,
        identity,
        session_id,
        session_sequence,
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
  session_id: String,
  session_sequence: Int,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
  count: Int,
) -> Result(#(String, ChannelState, List(types.TraceEvent)), String) {
  let batch = list.take(events, count)
  case
    next_encoded_event_batch(
      state,
      identity,
      session_id,
      session_sequence,
      mode,
      batch,
      encoding,
    )
  {
    Ok(#(frame, next)) -> Ok(#(frame, next, list.drop(events, count)))
    Error("frame_too_large") if count > 1 -> {
      let next_count = case int.divide(count, by: 2) {
        Ok(value) -> int.max(value, 1)
        Error(_) -> 1
      }
      fit_encoded_event_prefix(
        state,
        identity,
        session_id,
        session_sequence,
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
  session_id: String,
  session_sequence: Int,
  mode: relay_channel.Mode,
  events: List(types.TraceEvent),
  encoding: BatchEncoding,
) -> Result(#(String, ChannelState), String) {
  let event_count = list.length(events)
  case state, session_sequence > 0 {
    _, False -> Error("invalid_session_sequence")
    AwaitingCredit(_), _ -> Error("awaiting_credit")
    Stopped(_), _ -> Error("channel_stopped")
    Active(_, credits, _), True if credits <= 0 -> Error("credit_exhausted")
    Active(sequence, credits, limit), True -> {
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
              let session_payload =
                relay_session.encode_batch(
                  session_id,
                  session_sequence,
                  payload,
                )
              case
                string.byte_size(session_payload)
                > relay_wire.max_envelope_bytes
              {
                True -> Error("frame_too_large")
                False -> {
                  let next_sequence = sequence + 1
                  let frame =
                    relay_wire.sign_envelope(
                      identity,
                      next_sequence,
                      session_payload,
                    )
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
    Ok(stop) if stop.delivery_status != "" && stop.reason != "" ->
      Ok(Stopped(stop.delivery_status <> ":" <> stop.reason))
    _ -> Error("invalid_control")
  }
}

fn control_type_decoder() -> decode.Decoder(String) {
  use type_ <- decode.field("type", decode.string)
  decode.success(type_)
}

fn session_ack_decoder() -> decode.Decoder(SessionAckControl) {
  use protocol_version <- decode.field("protocol_version", decode.int)
  use session_id <- decode.field("session_id", decode.string)
  use sequence <- decode.field("sequence", decode.int)
  use delivery_status <- decode.field("delivery_status", decode.string)
  decode.success(SessionAckControl(
    protocol_version,
    session_id,
    sequence,
    delivery_status,
  ))
}

fn credit_decoder() -> decode.Decoder(CreditControl) {
  use protocol_version <- decode.field("protocol_version", decode.int)
  use credits <- decode.field("credits", decode.int)
  use max_batch_events <- decode.field("max_batch_events", decode.int)
  decode.success(CreditControl(protocol_version, credits, max_batch_events))
}

fn stop_decoder() -> decode.Decoder(StopControl) {
  use delivery_status <- decode.field("delivery_status", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(StopControl(delivery_status, reason))
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

fn session_mode(mode: relay_channel.Mode) -> relay_session.Mode {
  case mode {
    relay_channel.Exact -> relay_session.Exact
    relay_channel.Live -> relay_session.Live
  }
}

fn encoding_privacy(encoding: BatchEncoding) -> relay_session.Privacy {
  case encoding {
    MetadataEncoding -> relay_session.Metadata
    RawEncoding(_, _) -> relay_session.Raw
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

fn websocket_connect(url: String, hello: String) -> Result(Websocket, String) {
  websocket_connect_with_user_agent(
    url,
    hello,
    "beamtrace-relay/" <> runtime_version.current,
  )
}

@external(erlang, "beamtrace_websocket_client_ffi", "connect")
fn websocket_connect_with_user_agent(
  url: String,
  hello: String,
  user_agent: String,
) -> Result(Websocket, String)

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
