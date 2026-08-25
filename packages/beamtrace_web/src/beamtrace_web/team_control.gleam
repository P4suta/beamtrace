// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/page
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/json
import gleam/string
import lustre/effect.{type Effect}

pub fn load_traces(cursor: String) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    fetch_traces(
      cursor,
      fn(body) {
        case decode_traces(body) {
          Ok(page) -> dispatch(workspace.TeamTracesLoaded(page))
          Error(reason) -> dispatch(workspace.TeamTracesFailed(reason))
        }
      },
      fn(reason) { dispatch(workspace.TeamTracesFailed(reason)) },
    )
  })
}

pub fn load_events(trace_id: String, cursor: String) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    fetch_events(
      trace_id,
      cursor,
      fn(body) {
        case decode_events(body) {
          Ok(page) -> dispatch(workspace.TeamEventsLoaded(page))
          Error(reason) ->
            dispatch(workspace.TeamEventsFailed(trace_id, reason))
        }
      },
      fn(reason) { dispatch(workspace.TeamEventsFailed(trace_id, reason)) },
    )
  })
}

pub fn set_hold(trace_id: String, enabled: Bool) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    update_hold(
      trace_id,
      enabled,
      fn(body) {
        case decode_trace(body) {
          Ok(trace) -> dispatch(workspace.TraceHoldUpdated(trace))
          Error(reason) -> dispatch(workspace.TraceHoldFailed(reason))
        }
      },
      fn(reason) { dispatch(workspace.TraceHoldFailed(reason)) },
    )
  })
}

pub fn decode_traces(
  source: String,
) -> Result(workspace.TeamTracePage, String) {
  case json.parse(source, traces_decoder()) {
    Ok(page) -> Ok(page)
    Error(error) -> Error(string.inspect(error))
  }
}

pub fn decode_events(
  source: String,
) -> Result(workspace.TeamEventPage, String) {
  case json.parse(source, events_decoder()) {
    Ok(page) -> Ok(page)
    Error(error) -> Error(string.inspect(error))
  }
}

pub fn decode_trace(source: String) -> Result(workspace.TeamTrace, String) {
  case json.parse(source, trace_decoder()) {
    Ok(trace) -> Ok(trace)
    Error(error) -> Error(string.inspect(error))
  }
}

fn traces_decoder() -> decode.Decoder(workspace.TeamTracePage) {
  use traces <- decode.field("traces", decode.list(trace_decoder()))
  use next <- decode.field("next_cursor", decode.optional(decode.string))
  decode.success(workspace.TeamTracePage(traces, next))
}

fn events_decoder() -> decode.Decoder(workspace.TeamEventPage) {
  use trace_id <- decode.field("trace_id", decode.string)
  use events <- decode.field("events", decode.list(page.event_decoder()))
  use next <- decode.field("next_cursor", decode.optional(decode.string))
  decode.success(workspace.TeamEventPage(trace_id, events, next))
}

fn trace_decoder() -> decode.Decoder(workspace.TeamTrace) {
  use id <- decode.field("id", decode.string)
  use _deprecated_status <- decode.optional_field("status", "", decode.string)
  use node <- decode.field("node", decode.string)
  use mfa <- decode.field("mfa", mfa_decoder())
  use privacy <- decode.field("privacy", decode.string)
  use delivery_status <- decode.field("delivery_status", decode.string)
  use event_count <- decode.field("event_count", decode.int)
  use received_at_ms <- decode.field("received_at_ms", decode.int)
  use legal_hold <- decode.field("legal_hold", decode.bool)
  use locked <- decode.field("locked", decode.bool)
  decode.success(workspace.TeamTrace(
    id,
    node,
    mfa.0,
    mfa.1,
    mfa.2,
    privacy,
    delivery_status,
    event_count,
    received_at_ms,
    legal_hold,
    locked,
  ))
}

fn mfa_decoder() -> decode.Decoder(#(String, String, Int)) {
  use module_ <- decode.field("module", decode.string)
  use function_ <- decode.field("function", decode.string)
  use arity <- decode.field("arity", decode.int)
  decode.success(#(module_, function_, arity))
}

@external(javascript, "./team_control_ffi.mjs", "fetchTraces")
fn fetch_traces(
  cursor: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./team_control_ffi.mjs", "fetchEvents")
fn fetch_events(
  trace_id: String,
  cursor: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./team_control_ffi.mjs", "updateHold")
fn update_hold(
  trace_id: String,
  enabled: Bool,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil
