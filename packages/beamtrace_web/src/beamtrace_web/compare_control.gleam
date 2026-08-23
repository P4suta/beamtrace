// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/json
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
  use items <- decode.field("items", decode.list(item_decoder()))
  decode.success(workspace.CompareRun(path, added, removed, changed, items))
}

fn item_decoder() -> decode.Decoder(workspace.CompareItem) {
  use status <- decode.field("status", decode.string)
  use left_id <- decode.optional_field("left_id", "", decode.string)
  use right_id <- decode.optional_field("right_id", "", decode.string)
  use latency_delta_ns <- decode.optional_field(
    "latency_delta_ns",
    0,
    decode.int,
  )
  use reason <- decode.optional_field("reason", "", decode.string)
  case status {
    "matched" | "added" | "removed" | "changed" ->
      decode.success(workspace.CompareItem(
        status,
        left_id,
        right_id,
        latency_delta_ns,
        reason,
      ))
    _ ->
      decode.failure(
        workspace.CompareItem("", "", "", 0, ""),
        expected: "compare item status",
      )
  }
}

fn statistic_decoder() -> decode.Decoder(workspace.BranchStatistic) {
  use signature <- decode.field("signature", decode.string)
  use p50_ns <- decode.field("p50_ns", decode.int)
  use p95_ns <- decode.field("p95_ns", decode.int)
  use occurrences <- decode.field("occurrences", decode.int)
  use total_runs <- decode.field("total_runs", decode.int)
  use occurrence_rate <- decode.field("occurrence_rate", decode.float)
  decode.success(workspace.BranchStatistic(
    signature,
    p50_ns,
    p95_ns,
    occurrences,
    total_runs,
    occurrence_rate,
  ))
}

@external(javascript, "./compare_control_ffi.mjs", "requestCompare")
fn request_compare(
  body: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil
