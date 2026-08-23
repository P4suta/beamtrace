// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/compare_control
import beamtrace_web/workspace
import gleam/list
import gleeunit/should

pub fn compare_response_decodes_alignment_latency_and_multi_run_statistics_test() {
  let source =
    "{\"baseline\":\"left.beamtrace\",\"run_count\":3,\"reports\":[{"
    <> "\"path\":\"slow.beamtrace\",\"added\":1,\"removed\":0,\"changed\":0,"
    <> "\"items\":[{\"status\":\"matched\",\"left_id\":\"left-send\","
    <> "\"right_id\":\"right-send\",\"latency_delta_ns\":90},{"
    <> "\"status\":\"added\",\"right_id\":\"retry\"}]}],\"statistics\":[{"
    <> "\"signature\":\"orders|send:tag:work\",\"p50_ns\":10,\"p95_ns\":100,"
    <> "\"occurrences\":2,\"total_runs\":3,\"occurrence_rate\":0.6666667}]}"
  let assert Ok(report) = compare_control.decode_report(source)
  report.baseline |> should.equal("left.beamtrace")
  report.run_count |> should.equal(3)
  let assert Ok(run) = list.first(report.reports)
  run.items
  |> list.first
  |> should.equal(
    Ok(workspace.CompareItem("matched", "left-send", "right-send", 90, "")),
  )
  let assert Ok(statistic) = list.first(report.statistics)
  statistic.p95_ns |> should.equal(100)
  statistic.occurrences |> should.equal(2)
}

pub fn malformed_compare_response_is_rejected_test() {
  compare_control.decode_report("{}") |> should.be_error()
}
