// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/diff
import beamtrace/stats
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
  case report.added == 0 && report.removed == 0 && report.changed == 0 {
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
  let rows =
    list.map(statistics, fn(statistic) {
      statistic.signature
      <> " p50="
      <> int.to_string(statistic.p50_ns)
      <> "ns p95="
      <> int.to_string(statistic.p95_ns)
      <> "ns occurrence="
      <> int.to_string(statistic.occurrences)
      <> "/"
      <> int.to_string(statistic.total_runs)
    })
  case rows {
    [] -> headline
    _ -> headline <> "\n" <> string.join(rows, "\n")
  }
}
