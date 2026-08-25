// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/relay_payload
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

pub type Mode {
  Exact
  Live
}

pub type Privacy {
  Metadata
  Raw
}

pub type Completeness {
  Complete
  Truncated
  Incomplete
}

pub type Start {
  Start(
    session_id: String,
    relay_id: String,
    node: String,
    module_: String,
    function_: String,
    arity: Int,
    mode: Mode,
    privacy: Privacy,
    started_at_ms: Int,
  )
}

pub type End {
  End(
    session_id: String,
    sequence: Int,
    ended_at_ms: Int,
    completeness: Completeness,
  )
}

pub type Message {
  SessionStart(Start)
  Batch(
    session_id: String,
    sequence: Int,
    payload: String,
    batch: relay_payload.Batch,
  )
  SessionEnd(End)
  Heartbeat
}

type StartWire {
  StartWire(
    session_id: String,
    relay_id: String,
    node: String,
    module_: String,
    function_: String,
    arity: Int,
    mode: String,
    privacy: String,
    started_at_ms: Int,
    sequence: Int,
  )
}

type BatchWire {
  BatchWire(session_id: String, sequence: Int, payload: String)
}

type EndWire {
  EndWire(
    session_id: String,
    sequence: Int,
    ended_at_ms: Int,
    completeness: String,
  )
}

pub fn new_id() -> String {
  random_id()
}

pub fn encode_start(start: Start) -> String {
  json.object([
    #("type", json.string("session_start")),
    #("session_id", json.string(start.session_id)),
    #("relay_id", json.string(start.relay_id)),
    #("node", json.string(start.node)),
    #("module", json.string(start.module_)),
    #("function", json.string(start.function_)),
    #("arity", json.int(start.arity)),
    #("mode", json.string(mode_name(start.mode))),
    #("privacy", json.string(privacy_name(start.privacy))),
    #("started_at_ms", json.int(start.started_at_ms)),
    #("sequence", json.int(0)),
  ])
  |> json.to_string
}

pub fn encode_batch(
  session_id: String,
  sequence: Int,
  payload: String,
) -> String {
  json.object([
    #("type", json.string("batch")),
    #("session_id", json.string(session_id)),
    #("sequence", json.int(sequence)),
    #("payload", json.string(payload)),
  ])
  |> json.to_string
}

pub fn encode_end(end: End) -> String {
  json.object([
    #("type", json.string("session_end")),
    #("session_id", json.string(end.session_id)),
    #("sequence", json.int(end.sequence)),
    #("ended_at_ms", json.int(end.ended_at_ms)),
    #("completeness", json.string(completeness_name(end.completeness))),
  ])
  |> json.to_string
}

pub fn decode_message(source: String) -> Result(Message, String) {
  case json.parse(source, type_decoder()) {
    Ok("session_start") -> decode_start(source)
    Ok("batch") -> decode_batch(source)
    Ok("session_end") -> decode_end(source)
    Ok("heartbeat") -> Ok(Heartbeat)
    _ -> Error("invalid_session_message")
  }
}

fn decode_start(source: String) -> Result(Message, String) {
  case json.parse(source, start_decoder()) {
    Error(_) -> Error("invalid_session_start")
    Ok(wire) ->
      case
        valid_session_id(wire.session_id),
        valid_relay_id(wire.relay_id),
        valid_text(wire.node, 255),
        valid_text(wire.module_, 255),
        valid_text(wire.function_, 255),
        wire.arity >= 0 && wire.arity <= 255,
        parse_mode(wire.mode),
        parse_privacy(wire.privacy),
        wire.started_at_ms >= 0,
        wire.sequence == 0
      {
        True, True, True, True, True, True, Ok(mode), Ok(privacy), True, True ->
          Ok(
            SessionStart(Start(
              wire.session_id,
              wire.relay_id,
              wire.node,
              wire.module_,
              wire.function_,
              wire.arity,
              mode,
              privacy,
              wire.started_at_ms,
            )),
          )
        _, _, _, _, _, _, _, _, _, _ -> Error("invalid_session_start")
      }
  }
}

fn decode_batch(source: String) -> Result(Message, String) {
  case json.parse(source, batch_decoder()) {
    Error(_) -> Error("invalid_session_batch")
    Ok(wire) ->
      case
        valid_session_id(wire.session_id),
        wire.sequence > 0,
        relay_payload.decode_for_ingest(wire.payload)
      {
        True, True, Ok(batch) ->
          Ok(Batch(wire.session_id, wire.sequence, wire.payload, batch))
        False, _, _ | _, False, _ -> Error("invalid_session_batch")
        True, True, Error(error) -> Error(error)
      }
  }
}

fn decode_end(source: String) -> Result(Message, String) {
  case json.parse(source, end_decoder()) {
    Error(_) -> Error("invalid_session_end")
    Ok(wire) ->
      case
        valid_session_id(wire.session_id),
        wire.sequence > 0,
        wire.ended_at_ms >= 0,
        parse_completeness(wire.completeness)
      {
        True, True, True, Ok(completeness) ->
          Ok(
            SessionEnd(End(
              wire.session_id,
              wire.sequence,
              wire.ended_at_ms,
              completeness,
            )),
          )
        _, _, _, _ -> Error("invalid_session_end")
      }
  }
}

pub fn mode_name(mode: Mode) -> String {
  case mode {
    Exact -> "exact"
    Live -> "live"
  }
}

pub fn privacy_name(privacy: Privacy) -> String {
  case privacy {
    Metadata -> "metadata"
    Raw -> "raw"
  }
}

pub fn completeness_name(completeness: Completeness) -> String {
  case completeness {
    Complete -> "complete"
    Truncated -> "truncated"
    Incomplete -> "incomplete"
  }
}

fn parse_mode(value: String) -> Result(Mode, Nil) {
  case value {
    "exact" -> Ok(Exact)
    "live" -> Ok(Live)
    _ -> Error(Nil)
  }
}

fn parse_privacy(value: String) -> Result(Privacy, Nil) {
  case value {
    "metadata" -> Ok(Metadata)
    "raw" -> Ok(Raw)
    _ -> Error(Nil)
  }
}

fn parse_completeness(value: String) -> Result(Completeness, Nil) {
  case value {
    "complete" -> Ok(Complete)
    "truncated" -> Ok(Truncated)
    "incomplete" -> Ok(Incomplete)
    _ -> Error(Nil)
  }
}

fn valid_session_id(value: String) -> Bool {
  case bit_array.base16_decode(value) {
    Ok(bytes) ->
      bit_array.byte_size(bytes) == 16 && string.lowercase(value) == value
    Error(_) -> False
  }
}

fn valid_relay_id(value: String) -> Bool {
  case string.starts_with(value, "relay-") {
    False -> False
    True ->
      case bit_array.base16_decode(string.drop_start(value, 6)) {
        Ok(bytes) -> bit_array.byte_size(bytes) == 12
        Error(_) -> False
      }
  }
}

fn valid_text(value: String, maximum: Int) -> Bool {
  let size = string.byte_size(value)
  size > 0
  && size <= maximum
  && !list.any(["\u{0}", "\n", "\r"], fn(forbidden) {
    string.contains(value, forbidden)
  })
}

fn type_decoder() -> decode.Decoder(String) {
  use type_ <- decode.field("type", decode.string)
  decode.success(type_)
}

fn start_decoder() -> decode.Decoder(StartWire) {
  use session_id <- decode.field("session_id", decode.string)
  use relay_id <- decode.field("relay_id", decode.string)
  use node <- decode.field("node", decode.string)
  use module_ <- decode.field("module", decode.string)
  use function_ <- decode.field("function", decode.string)
  use arity <- decode.field("arity", decode.int)
  use mode <- decode.field("mode", decode.string)
  use privacy <- decode.field("privacy", decode.string)
  use started_at_ms <- decode.field("started_at_ms", decode.int)
  use sequence <- decode.field("sequence", decode.int)
  decode.success(StartWire(
    session_id,
    relay_id,
    node,
    module_,
    function_,
    arity,
    mode,
    privacy,
    started_at_ms,
    sequence,
  ))
}

fn batch_decoder() -> decode.Decoder(BatchWire) {
  use session_id <- decode.field("session_id", decode.string)
  use sequence <- decode.field("sequence", decode.int)
  use payload <- decode.field("payload", decode.string)
  decode.success(BatchWire(session_id, sequence, payload))
}

fn end_decoder() -> decode.Decoder(EndWire) {
  use session_id <- decode.field("session_id", decode.string)
  use sequence <- decode.field("sequence", decode.int)
  use ended_at_ms <- decode.field("ended_at_ms", decode.int)
  use completeness <- decode.field("completeness", decode.string)
  decode.success(EndWire(session_id, sequence, ended_at_ms, completeness))
}

@external(erlang, "beamtrace_relay_session_ffi", "new_id")
fn random_id() -> String
