// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/merge
import beamtrace/types
import gleam/option.{None}
import gleeunit/should

fn event(id: String, node: String, timestamp: Int) {
  types.TraceEvent(
    id: id,
    root_id: "root",
    node: node,
    process: types.ProcessIdentity(
      physical: types.ProcessRef(node, "<0.1.0>"),
      logical: None,
      evidence: [],
    ),
    local_timestamp_ns: timestamp,
    kind: types.Stop("done"),
    evidence: types.Exact,
  )
}

pub fn merge_applies_offsets_only_to_display_positions_test() {
  let result =
    merge.merge(
      [event("west", "west@host", 1000), event("east", "east@host", 0)],
      [
        merge.ClockEstimate("west@host", -1000, 40),
        merge.ClockEstimate("east@host", 100, 30),
      ],
      ["west@host", "east@host"],
    )

  result.events
  |> should.equal([
    merge.PositionedEvent(event("west", "west@host", 1000), 0, 40),
    merge.PositionedEvent(event("east", "east@host", 0), 100, 30),
  ])
  result.completeness |> should.equal(types.Complete)
}

pub fn overlapping_uncertainty_ranges_are_not_claimed_as_ordered_test() {
  let left = merge.PositionedEvent(event("left", "a@host", 0), 100, 50)
  let right = merge.PositionedEvent(event("right", "b@host", 0), 120, 50)

  merge.definitely_before(left, right) |> should.be_false()
  merge.bounds(left) |> should.equal(#(50, 150))
}

pub fn disconnected_expected_node_is_explicitly_partial_test() {
  merge.merge(
    [event("one", "one@host", 0)],
    [merge.ClockEstimate("one@host", 0, 0)],
    ["one@host", "missing@host"],
  ).completeness
  |> should.equal(types.PartialNode(["missing@host"]))
}
