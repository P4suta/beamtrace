// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/diff
import beamtrace/stats
import beamtrace/types
import beamtrace_runtime/cli
import beamtrace_runtime/command
import gleam/option.{None}
import gleeunit/should

pub fn export_output_paths_replace_agtrace_suffix_test() {
  command.export_path("capture.beamtrace", cli.Html)
  |> should.equal("capture.html")
  command.export_path("capture.beamtrace", cli.Jsonl)
  |> should.equal("capture.jsonl")
  command.export_path("capture.beamtrace", cli.Mermaid)
  |> should.equal("capture.mmd")
  command.export_path("capture.beamtrace", cli.Otlp)
  |> should.equal("capture.otlp.json")
}

pub fn compare_exit_code_is_policy_failure_only_when_different_test() {
  command.compare_exit(diff.DiffReport([], 0, 0, 0, 0, None))
  |> should.equal(0)
  command.compare_exit(diff.DiffReport([diff.Added("new")], 1, 0, 0, 0, None))
  |> should.equal(1)
}

pub fn compare_summary_includes_latency_percentiles_and_occurrence_test() {
  command.compare_summary(
    diff.DiffReport([diff.Added("new")], 1, 0, 0, 0, None),
    [
      stats.BranchStats(
        signature: "worker|send:tag:work",
        p50: types.TimeSummary(types.ExactTime(20), 2, 0),
        p95: types.TimeSummary(types.ExactTime(90), 2, 0),
        occurrences: 2,
        total_runs: 2,
      ),
    ],
  )
  |> should.equal(
    "Compare: +1 -0 ~0 ?0\n"
    <> "worker|send:tag:work p50=20ns exact samples=2/2 p95=90ns exact samples=2/2 occurrence=2/2",
  )
}
