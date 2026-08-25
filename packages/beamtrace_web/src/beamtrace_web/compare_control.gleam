// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/page
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import lustre/effect.{type Effect}

pub fn run(paths: List(String)) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    request_compare(
      json.object([#("paths", json.array(paths, json.string))])
        |> json.to_string,
      fn(body) {
        case decode_report(body) {
          Ok(report) -> dispatch(workspace.CompareLoaded(report))
          Error(reason) -> dispatch(workspace.CompareFailed(reason))
        }
      },
      fn(reason) { dispatch(workspace.CompareFailed(reason)) },
    )
  })
}

pub fn decode_report(
  source: String,
) -> Result(workspace.CompareReport, String) {
  case json.parse(source, report_decoder()) {
    Ok(report) -> Ok(report)
    Error(errors) -> Error(string.inspect(errors))
  }
}

fn report_decoder() -> decode.Decoder(workspace.CompareReport) {
  use baseline <- decode.field("baseline", decode.string)
  use run_count <- decode.field("run_count", decode.int)
  use reports <- decode.field("reports", decode.list(run_decoder()))
  use statistics <- decode.field("statistics", decode.list(statistic_decoder()))
  decode.success(workspace.CompareReport(
    baseline,
    run_count,
    reports,
    statistics,
  ))
}

fn run_decoder() -> decode.Decoder(workspace.CompareRun) {
  use path <- decode.field("path", decode.string)
  use added <- decode.field("added", decode.int)
  use removed <- decode.field("removed", decode.int)
  use changed <- decode.field("changed", decode.int)
  use ambiguity_count <- decode.field("ambiguity_count", decode.int)
  use first_divergence <- decode.field(
    "first_divergence",
    decode.optional(divergence_decoder()),
  )
  use items <- decode.field("items", decode.list(item_decoder()))
  decode.success(workspace.CompareRun(
    path,
    added,
    removed,
    changed,
    ambiguity_count,
    case first_divergence {
      Some(path) -> path
      None -> []
    },
    items,
  ))
}

fn divergence_decoder() -> decode.Decoder(List(String)) {
  use path <- decode.field("causal_path", decode.list(decode.string))
  decode.success(path)
}

fn item_decoder() -> decode.Decoder(workspace.CompareItem) {
  use status <- decode.field("status", decode.string)
  use left_id <- decode.optional_field("left_id", "", decode.string)
  use right_id <- decode.optional_field("right_id", "", decode.string)
  use latency_delta <- decode.optional_field(
    "latency_delta",
    workspace.TimeUnavailable("latency does not apply"),
    page.time_estimate_decoder(),
  )
  use left_ids <- decode.optional_field(
    "left_ids",
    [],
    decode.list(decode.string),
  )
  use right_ids <- decode.optional_field(
    "right_ids",
    [],
    decode.list(decode.string),
  )
  use reason <- decode.optional_field("reason", "", decode.string)
  case status {
    "matched" | "added" | "removed" | "changed" | "ambiguous" ->
      decode.success(workspace.CompareItem(
        status,
        case left_id, left_ids {
          "", [_, ..] -> string.join(left_ids, ", ")
          _, _ -> left_id
        },
        case right_id, right_ids {
          "", [_, ..] -> string.join(right_ids, ", ")
          _, _ -> right_id
        },
        latency_delta,
        reason,
      ))
    _ ->
      decode.failure(
        workspace.CompareItem(
          "",
          "",
          "",
          workspace.TimeUnavailable("invalid compare item"),
          "",
        ),
        expected: "compare item status",
      )
  }
}

fn statistic_decoder() -> decode.Decoder(workspace.BranchStatistic) {
  use signature <- decode.field("signature", decode.string)
  use p50 <- decode.field("p50", time_summary_decoder())
  use p95 <- decode.field("p95", time_summary_decoder())
  use occurrences <- decode.field("occurrences", decode.int)
  use total_runs <- decode.field("total_runs", decode.int)
  decode.success(workspace.BranchStatistic(
    signature,
    p50,
    p95,
    occurrences,
    total_runs,
  ))
}

fn time_summary_decoder() -> decode.Decoder(workspace.TimeSummary) {
  use estimate <- decode.field("estimate", page.time_estimate_decoder())
  use valid <- decode.field("valid_samples", decode.int)
  use missing <- decode.field("missing_samples", decode.int)
  decode.success(workspace.TimeSummary(estimate, valid, missing))
}

@external(javascript, "./compare_control_ffi.mjs", "requestCompare")
fn request_compare(
  body: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil
