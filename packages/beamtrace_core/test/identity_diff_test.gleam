import beamtrace/diff
import beamtrace/identity
import beamtrace/types
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn actor(node: String, pid: String, name: String) -> types.ProcessIdentity {
  identity.resolve(
    types.ProcessRef(node, pid),
    types.ProcessMetadata(
      registered_name: Some(name),
      process_label: None,
      initial_call: Some(types.Mfa("worker", "init", 1)),
      ancestors: ["supervisor"],
      supervisor_child_id: Some(name),
    ),
  )
}

fn event(id: String, pid: String, at: Int) -> types.TraceEvent {
  let process = actor("node@host", pid, "checkout_worker")
  types.TraceEvent(
    id: id,
    root_id: "root",
    node: "node@host",
    process: process,
    local_timestamp_ns: at,
    kind: types.Send(process.physical, types.Constructor("$gen_call", []), 1),
    evidence: types.Exact,
  )
}

pub fn logical_identity_survives_restart_test() {
  let before = actor("node@host", "<0.21.0>", "checkout_worker")
  let after = actor("node@host", "<0.99.0>", "checkout_worker")

  should.be_false(before.physical == after.physical)
  identity.same_logical_actor(before, after) |> should.be_true()
  after.evidence
  |> list.contains(types.SupervisorChildId("checkout_worker"))
  |> should.be_true()
}

pub fn compare_ignores_pid_and_node_local_time_test() {
  let report =
    diff.compare([event("left", "<0.21.0>", 10)], [
      event("right", "<0.99.0>", 9000),
    ])

  report.items
  |> should.equal([
    diff.Matched(left_id: "left", right_id: "right", latency_delta_ns: 0),
  ])
  report.added |> should.equal(0)
  report.removed |> should.equal(0)
}

pub fn compare_reports_relative_causal_latency_not_run_start_offset_test() {
  let report =
    diff.compare(
      [event("left-1", "<0.21.0>", 100), event("left-2", "<0.21.0>", 150)],
      [event("right-1", "<0.99.0>", 9000), event("right-2", "<0.99.0>", 9100)],
    )

  report.items
  |> should.equal([
    diff.Matched("left-1", "right-1", 0),
    diff.Matched("left-2", "right-2", 50),
  ])
}
