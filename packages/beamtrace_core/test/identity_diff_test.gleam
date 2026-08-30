import beamtrace/dag
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
    local_instant: types.LocalInstant(at, at),
    kind: types.Send(
      process.physical,
      types.Constructor("$gen_call", []),
      types.SequenceSerial(0, 1),
    ),
    evidence: types.Exact,
  )
}

fn named_event(
  id: String,
  pid: String,
  actor_name: String,
  tag: String,
  at: Int,
) -> types.TraceEvent {
  let process = actor("node@host", pid, actor_name)
  types.TraceEvent(
    id: id,
    root_id: "root",
    node: "node@host",
    process: process,
    local_instant: types.LocalInstant(at, at),
    kind: types.Send(
      process.physical,
      types.Tag(tag),
      types.SequenceSerial(at, at + 1),
    ),
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
    diff.Matched(
      left_id: "left",
      right_id: "right",
      latency_delta: types.ExactTime(0),
    ),
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
    diff.Matched("left-1", "right-1", types.ExactTime(0)),
    diff.Matched("left-2", "right-2", types.ExactTime(50)),
  ])
}

pub fn bounded_myers_aligns_unique_logical_signatures_without_guessing_test() {
  let report =
    diff.compare(
      [
        named_event("left-a", "<0.1.0>", "worker", "a", 1),
        named_event("left-c", "<0.1.0>", "worker", "c", 3),
      ],
      [
        named_event("right-a", "<0.2.0>", "worker", "a", 10),
        named_event("right-b", "<0.2.0>", "worker", "b", 20),
        named_event("right-c", "<0.2.0>", "worker", "c", 30),
      ],
    )

  report.added |> should.equal(1)
  report.removed |> should.equal(0)
  report.ambiguity_count |> should.equal(0)
  report.first_divergence |> should.not_equal(None)
}

pub fn unrelated_unique_signatures_are_added_and_removed_not_matched_test() {
  let report =
    diff.compare([named_event("left", "<0.1.0>", "worker", "left", 1)], [
      named_event("right", "<0.2.0>", "worker", "right", 1),
    ])

  report.added |> should.equal(1)
  report.removed |> should.equal(1)
  report.changed |> should.equal(0)
  report.ambiguity_count |> should.equal(0)
}

pub fn repeated_unanchored_signatures_are_explicitly_ambiguous_test() {
  let report =
    diff.compare(
      [
        named_event("left-1", "<0.1.0>", "worker", "repeat", 1),
        named_event("left-2", "<0.2.0>", "worker", "repeat", 2),
      ],
      [
        named_event("right-1", "<0.3.0>", "worker", "repeat", 10),
        named_event("right-2", "<0.4.0>", "worker", "repeat", 20),
      ],
    )

  report.items
  |> should.equal([
    diff.AmbiguousRegion(
      ["left-1", "left-2"],
      ["right-1", "right-2"],
      "repeated logical signatures do not have a unique alignment",
    ),
  ])
  report.ambiguity_count |> should.equal(1)
}

pub fn prepared_comparison_matches_compatibility_wrapper_test() {
  let left_branch = [
    named_event("left-a", "<0.1.0>", "worker", "a", 1),
    named_event("left-c", "<0.1.0>", "worker", "c", 3),
  ]
  let right_branch = [
    named_event("right-a", "<0.2.0>", "worker", "a", 10),
    named_event("right-b", "<0.2.0>", "worker", "b", 20),
    named_event("right-c", "<0.2.0>", "worker", "c", 30),
  ]
  let repeated_left = [
    named_event("left-1", "<0.3.0>", "worker", "repeat", 1),
    named_event("left-2", "<0.4.0>", "worker", "repeat", 2),
  ]
  let repeated_right = [
    named_event("right-1", "<0.5.0>", "worker", "repeat", 10),
    named_event("right-2", "<0.6.0>", "worker", "repeat", 20),
  ]
  let duplicate_ids = [
    named_event("duplicate", "<0.7.0>", "worker", "a", 1),
    named_event("duplicate", "<0.7.0>", "worker", "b", 2),
  ]
  let cases = [
    #(left_branch, left_branch),
    #(left_branch, right_branch),
    #(right_branch, left_branch),
    #(repeated_left, repeated_right),
    #(duplicate_ids, right_branch),
  ]

  list.each(cases, fn(pair) {
    case diff.prepare(pair.0), diff.prepare(pair.1) {
      Ok(left), Ok(right) ->
        diff.compare_prepared(left, right)
        |> should.equal(diff.compare(pair.0, pair.1))
      Error(_), _ | _, Error(_) -> Nil
    }
  })
}

pub fn checked_comparison_rejects_duplicate_event_ids_test() {
  let duplicates = [
    named_event("duplicate", "<0.7.0>", "worker", "a", 1),
    named_event("duplicate", "<0.7.0>", "worker", "b", 2),
  ]

  diff.prepare(duplicates)
  |> should.equal(Error(dag.DuplicateEventId("duplicate")))
  diff.compare_checked(duplicates, [])
  |> should.equal(Error(dag.DuplicateEventId("duplicate")))
}
