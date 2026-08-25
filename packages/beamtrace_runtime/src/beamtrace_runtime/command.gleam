// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/diff
import beamtrace/stats
import beamtrace/types
import beamtrace_runtime/cli
import gleam/int
import gleam/list
import gleam/string

pub fn export_path(path: String, format: cli.ExportFormat) -> String {
  let stem = case string.ends_with(path, ".beamtrace") {
    True -> string.drop_end(path, string.length(".beamtrace"))
    False -> path
  }
  stem
  <> case format {
    cli.Html -> ".html"
    cli.Jsonl -> ".jsonl"
    cli.Mermaid -> ".mmd"
    cli.Otlp -> ".otlp.json"
  }
}

pub fn compare_exit(report: diff.DiffReport) -> Int {
  case
    report.added == 0
    && report.removed == 0
    && report.changed == 0
    && report.ambiguity_count == 0
  {
    True -> 0
    False -> 1
  }
}

pub fn compare_summary(
  report: diff.DiffReport,
  statistics: List(stats.BranchStats),
) -> String {
  let headline =
    "Compare: +"
    <> int.to_string(report.added)
    <> " -"
    <> int.to_string(report.removed)
    <> " ~"
    <> int.to_string(report.changed)
    <> " ?"
    <> int.to_string(report.ambiguity_count)
  let rows =
    list.map(statistics, fn(statistic) {
      statistic.signature
      <> " p50="
      <> time_summary_text(statistic.p50)
      <> " p95="
      <> time_summary_text(statistic.p95)
      <> " occurrence="
      <> int.to_string(statistic.occurrences)
      <> "/"
      <> int.to_string(statistic.total_runs)
    })
  case rows {
    [] -> headline
    _ -> headline <> "\n" <> string.join(rows, "\n")
  }
}

fn time_summary_text(summary: types.TimeSummary) -> String {
  let estimate = case summary.estimate {
    types.ExactTime(value) -> int.to_string(value) <> "ns exact"
    types.EstimatedTime(value, lower, upper) ->
      int.to_string(value)
      <> "ns ["
      <> int.to_string(lower)
      <> ","
      <> int.to_string(upper)
      <> "]"
    types.TimeUnavailable(reason) -> "unavailable(" <> reason <> ")"
  }
  estimate
  <> " samples="
  <> int.to_string(summary.valid_samples)
  <> "/"
  <> int.to_string(summary.valid_samples + summary.missing_samples)
}
