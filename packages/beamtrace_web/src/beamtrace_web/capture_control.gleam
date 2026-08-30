// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import lustre/effect.{type Effect}

type StatusPayload {
  StatusPayload(
    status: String,
    event_count: Int,
    outcome: String,
    delivery_verified: Bool,
    issue_count: Int,
    issue_summary: String,
    reason: String,
  )
}

type IssuePayload {
  IssuePayload(kind: String, node: String)
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
        "ready" | "sealed" ->
          Ok(workspace.Ready(
            payload.event_count,
            payload.outcome
              <> case payload.delivery_verified {
              True -> " · delivery verified"
              False ->
                case payload.issue_count {
                  0 -> " · delivery unverified"
                  count ->
                    " · integrity issues present ("
                    <> int.to_string(count)
                    <> ")"
                    <> case payload.issue_summary {
                      "" -> ""
                      summary -> ": " <> summary
                    }
                }
            },
          ))
        "failed" -> Ok(workspace.Failed(payload.reason))
        _ -> Error("unknown capture status")
      }
  }
}

fn status_decoder() -> decode.Decoder(StatusPayload) {
  use status <- decode.field("status", decode.string)
  use event_count <- decode.optional_field("event_count", 0, decode.int)
  use outcome <- decode.optional_field("outcome", "sealed", outcome_decoder())
  use delivery_verified <- decode.optional_field(
    "delivery_verified",
    False,
    decode.bool,
  )
  use issue_count <- decode.optional_field(
    "outcome",
    0,
    outcome_issue_count_decoder(),
  )
  use issue_summary <- decode.optional_field(
    "outcome",
    "",
    outcome_issue_summary_decoder(),
  )
  use reason <- decode.optional_field("reason", "", decode.string)
  decode.success(StatusPayload(
    status,
    event_count,
    outcome,
    delivery_verified,
    issue_count,
    issue_summary,
    reason,
  ))
}

fn outcome_decoder() -> decode.Decoder(String) {
  use end <- decode.field("end", outcome_end_decoder())
  decode.success(end)
}

fn outcome_issue_count_decoder() -> decode.Decoder(Int) {
  use issues <- decode.field("issues", decode.list(decode.dynamic))
  decode.success(list.length(issues))
}

fn outcome_issue_summary_decoder() -> decode.Decoder(String) {
  use issues <- decode.field("issues", decode.list(issue_decoder()))
  issues
  |> list.take(3)
  |> list.map(issue_label)
  |> list.intersperse("; ")
  |> list.fold("", fn(summary, part) { summary <> part })
  |> decode.success
}

fn issue_decoder() -> decode.Decoder(IssuePayload) {
  use kind <- decode.field("kind", decode.string)
  use node <- decode.optional_field("node", "", decode.string)
  decode.success(IssuePayload(kind, node))
}

fn issue_label(issue: IssuePayload) -> String {
  let label = case issue.kind {
    "dropped_events" -> "dropped events"
    "missing_node" -> "missing final node receipt"
    "batch_sequence_gap" -> "batch sequence gap"
    "duplicate_batch" -> "duplicate batch"
    "receipt_mismatch" -> "receipt mismatch"
    "drain_timeout" -> "drain timeout"
    "legacy_unverified" -> "legacy archive is unverified"
    _ -> "unrecognized integrity issue"
  }
  case issue.node {
    "" -> label
    node -> label <> " on " <> node
  }
}

fn outcome_end_decoder() -> decode.Decoder(String) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "quiet_period" -> {
      use quiet_ms <- decode.field("quiet_ms", decode.int)
      decode.success(
        "sealed after " <> int.to_string(quiet_ms) <> "ms quiet period",
      )
    }
    "time_window" -> {
      use window_ms <- decode.field("window_ms", decode.int)
      decode.success("sealed after " <> int.to_string(window_ms) <> "ms window")
    }
    "user_stopped" -> decode.success("sealed after user stop")
    "budget_reached" -> decode.success("sealed after budget limit")
    "agent_failure" -> decode.success("sealed after agent failure")
    "legacy_unknown" -> decode.success("legacy observation end unknown")
    _ -> decode.failure("", expected: "observation end")
  }
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
