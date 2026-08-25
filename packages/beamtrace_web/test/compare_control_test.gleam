// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/compare_control
import beamtrace_web/workspace
import gleam/list
import gleeunit/should

pub fn compare_response_decodes_alignment_latency_and_multi_run_statistics_test() {
  let source =
    "{\"baseline\":\"left.beamtrace\",\"run_count\":3,\"reports\":[{"
    <> "\"path\":\"slow.beamtrace\",\"added\":1,\"removed\":0,\"changed\":0,"
    <> "\"ambiguity_count\":0,\"first_divergence\":null,"
    <> "\"items\":[{\"status\":\"matched\",\"left_id\":\"left-send\","
    <> "\"right_id\":\"right-send\",\"latency_delta\":{\"kind\":\"exact\","
    <> "\"value_ns\":\"90\"}},{"
    <> "\"status\":\"added\",\"right_id\":\"retry\"}]}],\"statistics\":[{"
    <> "\"signature\":\"orders|send:tag:work\","
    <> "\"p50\":{\"estimate\":{\"kind\":\"exact\",\"value_ns\":\"10\"},"
    <> "\"valid_samples\":2,\"missing_samples\":0},"
    <> "\"p95\":{\"estimate\":{\"kind\":\"estimated\",\"value_ns\":\"100\","
    <> "\"lower_ns\":\"95\",\"upper_ns\":\"105\"},"
    <> "\"valid_samples\":2,\"missing_samples\":1},"
    <> "\"occurrences\":2,\"total_runs\":3}]}"
  let assert Ok(report) = compare_control.decode_report(source)
  report.baseline |> should.equal("left.beamtrace")
  report.run_count |> should.equal(3)
  let assert Ok(run) = list.first(report.reports)
  run.items
  |> list.first
  |> should.equal(
    Ok(workspace.CompareItem(
      "matched",
      "left-send",
      "right-send",
      workspace.ExactTime("90"),
      "",
    )),
  )
  let assert Ok(statistic) = list.first(report.statistics)
  statistic.p95
  |> should.equal(workspace.TimeSummary(
    workspace.EstimatedTime("100", "95", "105"),
    2,
    1,
  ))
  statistic.occurrences |> should.equal(2)
}

pub fn malformed_compare_response_is_rejected_test() {
  compare_control.decode_report("{}") |> should.be_error()
}
