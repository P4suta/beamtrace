// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/json
import gleam/list
import lustre/effect.{type Effect}

type StatusPayload {
  StatusPayload(
    status: String,
    event_count: Int,
    completeness: String,
    reason: String,
  )
}

type MfaCandidatePayload {
  MfaCandidatePayload(mfa: String)
}

type MfaSearchPayload {
  MfaSearchPayload(candidates: List(MfaCandidatePayload))
}

pub fn arm(
  trigger: String,
  where_aql: String,
  preset: String,
  max_roots: String,
) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    arm_capture(
      trigger,
      where_aql,
      preset,
      max_roots,
      fn(_body) { dispatch(workspace.CaptureArmAccepted) },
      fn(reason) { dispatch(workspace.CaptureArmFailed(reason)) },
    )
  })
}

pub fn status() -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    fetch_status(
      fn(body) {
        case decode_status(body) {
          Ok(phase) -> dispatch(workspace.CaptureStatusLoaded(phase))
          Error(reason) -> dispatch(workspace.CaptureArmFailed(reason))
        }
      },
      fn(_reason) {
        dispatch(workspace.CaptureStatusLoaded(workspace.Unavailable))
      },
    )
  })
}

pub fn search_mfas(query: String) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    search_target_mfas(
      query,
      fn(body) {
        case decode_mfas(body) {
          Ok(candidates) -> dispatch(workspace.MfaSuggestionsLoaded(candidates))
          Error(_) -> dispatch(workspace.MfaSuggestionsLoaded([]))
        }
      },
      fn(_reason) { dispatch(workspace.MfaSuggestionsLoaded([])) },
    )
  })
}

pub fn decode_mfas(source: String) -> Result(List(String), String) {
  case json.parse(source, mfa_search_decoder()) {
    Error(_) -> Error("invalid MFA search response")
    Ok(payload) ->
      Ok(payload.candidates |> list.map(fn(candidate) { candidate.mfa }))
  }
}

pub fn poll_after(delay_ms: Int) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    schedule(delay_ms, fn() { dispatch(workspace.PollCaptureStatus) })
  })
}

pub fn cancel() -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    cancel_capture(
      fn(_body) {
        dispatch(workspace.CaptureStatusLoaded(workspace.Cancelling))
      },
      fn(reason) { dispatch(workspace.CaptureCancelFailed(reason)) },
    )
  })
}

pub fn save(path: String) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    save_capture(
      path,
      fn(_body) { dispatch(workspace.CaptureSaved(path)) },
      fn(reason) { dispatch(workspace.CaptureSaveFailed(reason)) },
    )
  })
}

pub fn install_cleanup() -> Effect(workspace.Msg) {
  effect.from(fn(_dispatch) { install_page_cleanup() })
}

pub fn decode_status(source: String) -> Result(workspace.CapturePhase, String) {
  case json.parse(source, status_decoder()) {
    Error(_) -> Error("invalid capture status")
    Ok(payload) ->
      case payload.status {
        "idle" -> Ok(workspace.Idle)
        "armed" -> Ok(workspace.Armed)
        "cancelling" -> Ok(workspace.Cancelling)
        "ready" ->
          Ok(workspace.Ready(payload.event_count, payload.completeness))
        "failed" -> Ok(workspace.Failed(payload.reason))
        _ -> Error("unknown capture status")
      }
  }
}

fn status_decoder() -> decode.Decoder(StatusPayload) {
  use status <- decode.field("status", decode.string)
  use event_count <- decode.optional_field("event_count", 0, decode.int)
  use completeness <- decode.optional_field("completeness", "", decode.string)
  use reason <- decode.optional_field("reason", "", decode.string)
  decode.success(StatusPayload(status, event_count, completeness, reason))
}

fn mfa_search_decoder() -> decode.Decoder(MfaSearchPayload) {
  use candidates <- decode.field(
    "candidates",
    decode.list(mfa_candidate_decoder()),
  )
  decode.success(MfaSearchPayload(candidates))
}

fn mfa_candidate_decoder() -> decode.Decoder(MfaCandidatePayload) {
  use mfa <- decode.field("mfa", decode.string)
  decode.success(MfaCandidatePayload(mfa))
}

@external(javascript, "./capture_control_ffi.mjs", "armCapture")
fn arm_capture(
  trigger: String,
  where_aql: String,
  preset: String,
  max_roots: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./capture_control_ffi.mjs", "fetchCaptureStatus")
fn fetch_status(
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./capture_control_ffi.mjs", "searchMfas")
fn search_target_mfas(
  query: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./capture_control_ffi.mjs", "cancelCapture")
fn cancel_capture(
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./capture_control_ffi.mjs", "saveCapture")
fn save_capture(
  path: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./capture_control_ffi.mjs", "schedule")
fn schedule(delay_ms: Int, callback: fn() -> Nil) -> Nil

@external(javascript, "./capture_control_ffi.mjs", "installPageCleanup")
fn install_page_cleanup() -> Nil
