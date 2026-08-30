// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/merge
import beamtrace/types
import gleam/option.{None, Some}
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
    local_instant: types.LocalInstant(timestamp, timestamp),
    kind: types.Stop("done"),
    evidence: types.Exact,
  )
}

pub fn merge_applies_offsets_only_to_display_positions_test() {
  let clocks =
    types.ClockCalibration(1, [
      types.NodeClock(
        "west@host",
        1000,
        Some(types.ClockSample(1000, 0, 40, 80)),
        Some(types.ClockSample(2000, 1000, 40, 80)),
      ),
      types.NodeClock(
        "east@host",
        0,
        Some(types.ClockSample(0, 100, 30, 60)),
        Some(types.ClockSample(1000, 1100, 30, 60)),
      ),
    ])
  let result =
    merge.merge(
      [event("west", "west@host", 0), event("east", "east@host", 0)],
      clocks,
      ["west@host", "east@host"],
    )

  result.events
  |> should.equal([
    merge.PositionedEvent(
      event("west", "west@host", 0),
      types.EstimatedTime(0, -40, 40),
    ),
    merge.PositionedEvent(
      event("east", "east@host", 0),
      types.EstimatedTime(100, 70, 130),
    ),
  ])
  result.issues |> should.equal([])
}

pub fn overlapping_uncertainty_ranges_are_not_claimed_as_ordered_test() {
  let left =
    merge.PositionedEvent(
      event("left", "a@host", 0),
      types.EstimatedTime(100, 50, 150),
    )
  let right =
    merge.PositionedEvent(
      event("right", "b@host", 0),
      types.EstimatedTime(120, 70, 170),
    )

  merge.definitely_before(left, right) |> should.be_false()
  merge.bounds(left.time) |> should.equal(Ok(#(50, 150)))
}

pub fn inverted_uncertainty_ranges_are_rejected_test() {
  let invalid = types.EstimatedTime(100, 150, 50)
  merge.bounds(invalid)
  |> should.equal(Error("estimated time lower bound exceeds upper bound"))

  let left = merge.PositionedEvent(event("left", "a@host", 0), invalid)
  let right =
    merge.PositionedEvent(
      event("right", "b@host", 0),
      types.EstimatedTime(200, 180, 220),
    )
  merge.definitely_before(left, right) |> should.be_false()
}

pub fn disconnected_expected_node_is_explicitly_partial_test() {
  let result =
    merge.merge(
      [event("one", "one@host", 0)],
      types.ClockCalibration(1, [
        types.NodeClock(
          "one@host",
          0,
          Some(types.ClockSample(0, 100, 0, 0)),
          Some(types.ClockSample(1000, 1100, 0, 0)),
        ),
      ]),
      ["one@host", "missing@host"],
    )
  result.issues |> should.equal([types.MissingNode("missing@host")])
}

pub fn same_node_duration_is_exact_test() {
  let first =
    merge.PositionedEvent(
      event("first", "one@host", 10),
      types.TimeUnavailable("not needed"),
    )
  let second =
    merge.PositionedEvent(
      event("second", "one@host", 35),
      types.TimeUnavailable("not needed"),
    )
  merge.duration(first, second) |> should.equal(types.ExactTime(25))
}

pub fn skew_drift_and_asymmetric_jitter_are_interpolated_test() {
  let calibration =
    types.ClockCalibration(1, [
      types.NodeClock(
        "drifting@host",
        1000,
        Some(types.ClockSample(1000, 5000, 10, 20)),
        Some(types.ClockSample(2000, 6200, 50, 100)),
      ),
    ])

  merge.calibrated_time(event("mid", "drifting@host", 500), calibration)
  |> should.equal(types.EstimatedTime(5600, 5570, 5630))
}

pub fn negative_calibrated_center_is_preserved_test() {
  let calibration =
    types.ClockCalibration(1, [
      types.NodeClock(
        "negative@host",
        100,
        Some(types.ClockSample(100, -1000, 25, 50)),
        Some(types.ClockSample(200, -900, 25, 50)),
      ),
    ])

  merge.calibrated_time(event("negative", "negative@host", 0), calibration)
  |> should.equal(types.EstimatedTime(-1000, -1025, -975))
}

pub fn missing_either_probe_makes_cross_node_time_unavailable_test() {
  let calibration =
    types.ClockCalibration(1, [
      types.NodeClock(
        "partial@host",
        0,
        Some(types.ClockSample(0, 100, 5, 10)),
        None,
      ),
    ])

  merge.calibrated_time(event("partial", "partial@host", 0), calibration)
  |> should.equal(types.TimeUnavailable(
    "before and after clock probes are required",
  ))
}

pub fn cross_node_duration_subtracts_full_intervals_test() {
  let from =
    merge.PositionedEvent(
      event("from", "a@host", 0),
      types.EstimatedTime(100, 80, 130),
    )
  let to =
    merge.PositionedEvent(
      event("to", "b@host", 0),
      types.EstimatedTime(250, 220, 290),
    )

  merge.duration(from, to)
  |> should.equal(types.EstimatedTime(150, 90, 210))
}

pub fn bounds_error_is_the_unavailable_reason_test() {
  merge.bounds(types.TimeUnavailable("no_calibration"))
  |> should.equal(Error("no_calibration"))
  merge.bounds(types.EstimatedTime(10, 5, 15)) |> should.equal(Ok(#(5, 15)))
}
