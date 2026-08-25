// SPDX-License-Identifier: Apache-2.0 OR MIT

import beamtrace_tui/model
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string

pub fn load_traces(
  server_url: String,
  session_cookie_file: String,
) -> Result(List(model.TeamTrace), String) {
  use session <- result_try(read_session_file(session_cookie_file))
  use body <- result_try(fetch_trace_page(server_url, session))
  decode_traces(body)
}

pub fn decode_traces(body: String) -> Result(List(model.TeamTrace), String) {
  case string.byte_size(body) <= 1_048_576, json.parse(body, page_decoder()) {
    False, _ -> Error("team trace response exceeded 1 MiB")
    _, Error(_) -> Error("team trace response was invalid")
    True, Ok(traces) -> Ok(list.take(traces, 100))
  }
}

fn page_decoder() -> decode.Decoder(List(model.TeamTrace)) {
  use traces <- decode.field("traces", decode.list(trace_decoder()))
  decode.success(traces)
}

fn trace_decoder() -> decode.Decoder(model.TeamTrace) {
  use id <- decode.field("id", decode.string)
  use delivery_status <- decode.field("delivery_status", decode.string)
  use node <- decode.field("node", decode.string)
  use mfa <- decode.field("mfa", mfa_decoder())
  use privacy <- decode.field("privacy", decode.string)
  use event_count <- decode.field("event_count", decode.int)
  use received_at_ms <- decode.field("received_at_ms", decode.int)
  use locked <- decode.field("locked", decode.bool)
  decode.success(model.TeamTrace(
    id,
    delivery_status,
    node,
    mfa.0 <> ":" <> mfa.1 <> "/" <> int.to_string(mfa.2),
    privacy,
    event_count,
    received_at_ms,
    locked,
  ))
}

fn mfa_decoder() -> decode.Decoder(#(String, String, Int)) {
  use module_ <- decode.field("module", decode.string)
  use function_ <- decode.field("function", decode.string)
  use arity <- decode.field("arity", decode.int)
  decode.success(#(module_, function_, arity))
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

@external(erlang, "beamtrace_team_tui_ffi", "read_session_file")
fn read_session_file(path: String) -> Result(String, String)

@external(erlang, "beamtrace_team_tui_ffi", "fetch_trace_page")
fn fetch_trace_page(
  server_url: String,
  session: String,
) -> Result(String, String)
