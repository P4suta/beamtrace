// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/stats
import beamtrace/types
import gleam/option.{Some}
import gleeunit/should

pub fn multi_run_branch_statistics_include_percentiles_and_occurrence_test() {
  stats.summarize([
    [stats.BranchSample("call>reply", 10)],
    [stats.BranchSample("call>reply", 20)],
    [],
    [stats.BranchSample("call>reply", 100)],
  ])
  |> should.equal([
    stats.BranchStats(
      signature: "call>reply",
      p50_ns: 20,
      p95_ns: 100,
      occurrences: 3,
      total_runs: 4,
      occurrence_rate: 0.75,
    ),
  ])
}

pub fn empty_runs_have_no_invented_statistics_test() {
  stats.summarize([[], []]) |> should.equal([])
}

fn event(
  id: String,
  pid: String,
  timestamp_ns: Int,
  kind: types.TraceEventKind,
) {
  types.TraceEvent(
    id: id,
    root_id: "root",
    node: "fixture@host",
    process: types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", pid),
      logical: Some(types.LogicalActor("checkout-worker", "Checkout worker")),
      evidence: [],
    ),
    local_timestamp_ns: timestamp_ns,
    kind: kind,
    evidence: types.Exact,
  )
}

pub fn trace_statistics_are_pid_and_clock_origin_independent_test() {
  let first = [
    event(
      "a-root",
      "<0.1.0>",
      1000,
      types.Root(types.Mfa("shop", "checkout", 1), []),
    ),
    event("a-stop", "<0.1.0>", 1020, types.Stop("complete")),
  ]
  let second = [
    event(
      "b-root",
      "<0.99.0>",
      90_000,
      types.Root(types.Mfa("shop", "checkout", 1), []),
    ),
    event("b-stop", "<0.99.0>", 90_100, types.Stop("complete")),
  ]

  stats.from_traces([first, second])
  |> should.equal([
    stats.BranchStats(
      signature: "checkout-worker|root:shop:checkout/1:",
      p50_ns: 0,
      p95_ns: 0,
      occurrences: 2,
      total_runs: 2,
      occurrence_rate: 1.0,
    ),
    stats.BranchStats(
      signature: "checkout-worker|stop:complete",
      p50_ns: 20,
      p95_ns: 100,
      occurrences: 2,
      total_runs: 2,
      occurrence_rate: 1.0,
    ),
  ])
}

pub fn duplicate_event_shapes_count_once_per_run_but_keep_latency_samples_test() {
  let run = [
    event("root", "<0.1.0>", 10, types.Stop("complete")),
    event("again", "<0.1.0>", 30, types.Stop("complete")),
  ]

  stats.from_traces([run])
  |> should.equal([
    stats.BranchStats(
      signature: "checkout-worker|stop:complete",
      p50_ns: 0,
      p95_ns: 20,
      occurrences: 1,
      total_runs: 1,
      occurrence_rate: 1.0,
    ),
  ])
}
