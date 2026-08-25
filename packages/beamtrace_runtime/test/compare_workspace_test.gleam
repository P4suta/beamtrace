// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/diff
import beamtrace/types
import beamtrace_runtime/compare_workspace
import beamtrace_runtime/storage
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import v2_fixture

pub fn multi_trace_compare_loads_archives_and_reports_pid_independent_stats_test() {
  let left = "build/compare-workspace-left.beamtrace"
  let slow = "build/compare-workspace-slow.beamtrace"
  let missing = "build/compare-workspace-missing.beamtrace"
  save_run(left, "<0.1.0>", 10, Some(20))
  save_run(slow, "<0.99.0>", 1000, Some(1100))
  save_run(missing, "<0.55.0>", 90_000, None)

  let assert Ok(report) = compare_workspace.compare([left, slow, missing])
  report.baseline |> should.equal(left)
  report.run_count |> should.equal(3)
  report.reports |> list.length |> should.equal(2)
  let assert [slow_report, missing_report] = report.reports
  slow_report.items
  |> list.any(fn(item) {
    item == diff.Matched("send-<0.1.0>", "send-<0.99.0>", types.ExactTime(90))
  })
  |> should.be_true()
  missing_report.removed |> should.equal(1)

  let send_stats =
    report.statistics
    |> list.find(fn(item) { item.signature == "orders|send:tag:work" })
  let assert Ok(send_stats) = send_stats
  send_stats.p50
  |> should.equal(types.TimeSummary(types.ExactTime(10), 2, 0))
  send_stats.p95
  |> should.equal(types.TimeSummary(types.ExactTime(100), 2, 0))
  send_stats.occurrences |> should.equal(2)
  send_stats.total_runs |> should.equal(3)
}

pub fn compare_rejects_unbounded_or_non_trace_path_sets_test() {
  compare_workspace.compare(["only.beamtrace"])
  |> should.equal(Error(compare_workspace.InvalidPaths))
  compare_workspace.compare(["left.beamtrace", "right.zip"])
  |> should.equal(Error(compare_workspace.InvalidPaths))
}

fn save_run(path: String, pid: String, root_at: Int, send_at: Option(Int)) {
  let root = event("root-" <> pid, pid, root_at, types.Stop("root"))
  let events = case send_at {
    Some(at) -> [
      root,
      event(
        "send-" <> pid,
        pid,
        at,
        types.Send(
          types.ProcessRef("fixture@host", "<0.7.0>"),
          types.Tag("work"),
          v2_fixture.serial(1),
        ),
      ),
    ]
    None -> [root]
  }
  let manifest = v2_fixture.manifest("compare-" <> pid, ["fixture@host"])
  storage.save(path, manifest, events) |> should.equal(Ok(Nil))
}

fn event(id: String, pid: String, at: Int, kind: types.TraceEventKind) {
  types.TraceEvent(
    id,
    "root",
    "fixture@host",
    types.ProcessIdentity(
      types.ProcessRef("fixture@host", pid),
      Some(types.LogicalActor("orders", "Orders")),
      [],
    ),
    v2_fixture.instant(at),
    kind,
    types.Exact,
  )
}
