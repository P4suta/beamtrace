//// Merge distributed partial orders and calibrated time intervals.
////
//// Merge retains unavailable time, uncertainty intervals, and boundaries;
//// it never converts offsets into an unqualified global clock. Invalid bounds
//// return `Error`. Ordering is O((n + e) log n) and deterministic on Erlang
//// and JavaScript.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// An event paired with exact, estimated, or unavailable display time.
pub type PositionedEvent {
  PositionedEvent(event: types.TraceEvent, time: types.TimeEstimate)
}

/// Calibrated events plus integrity issues discovered during merge.
pub type MergeResult {
  MergeResult(events: List(PositionedEvent), issues: List(types.CaptureIssue))
}

/// Apply the before/after minimum-RTT calibration model for display only.
/// Event order is deliberately preserved; callers use causal topology rather
/// than a cross-node wall-clock sort.
pub fn merge(
  events: List(types.TraceEvent),
  calibration: types.ClockCalibration,
  expected_nodes: List(String),
) -> MergeResult {
  let observed = unique(list.map(events, fn(event) { event.node }), [])
  let missing =
    list.filter(expected_nodes, fn(node) { !list.contains(observed, node) })
  let missing_issues = list.map(missing, types.MissingNode)
  let positioned =
    list.map(events, fn(event) {
      PositionedEvent(event, calibrated_time(event, calibration))
    })
  MergeResult(positioned, missing_issues)
}

/// Project one node-local instant through before/after clock samples in
/// O(nodes). Missing probes yield `TimeUnavailable`; intervals are preserved.
pub fn calibrated_time(
  event: types.TraceEvent,
  calibration: types.ClockCalibration,
) -> types.TimeEstimate {
  case find_clock(calibration.nodes, event.node) {
    None -> types.TimeUnavailable("clock calibration is missing")
    Some(types.NodeClock(_, origin, before, after)) ->
      case before, after {
        Some(before), Some(after) -> {
          let local = origin + event.local_instant.offset_ns
          let before_uncertainty = int.absolute_value(before.uncertainty_ns)
          let after_uncertainty = int.absolute_value(after.uncertainty_ns)
          let center =
            interpolate_offset(
              local,
              before,
              after,
              before.unix_midpoint_ns - before.local_ns,
              after.unix_midpoint_ns - after.local_ns,
            )
          let lower =
            interpolate_offset(
              local,
              before,
              after,
              before.unix_midpoint_ns - before_uncertainty - before.local_ns,
              after.unix_midpoint_ns - after_uncertainty - after.local_ns,
            )
          let upper =
            interpolate_offset(
              local,
              before,
              after,
              before.unix_midpoint_ns + before_uncertainty - before.local_ns,
              after.unix_midpoint_ns + after_uncertainty - after.local_ns,
            )
          types.EstimatedTime(center, lower, upper)
        }
        _, _ ->
          types.TimeUnavailable("before and after clock probes are required")
      }
  }
}

fn interpolate_offset(
  local: Int,
  before: types.ClockSample,
  after: types.ClockSample,
  before_offset: Int,
  after_offset: Int,
) -> Int {
  let span = after.local_ns - before.local_ns
  case span <= 0 {
    True -> local + before_offset
    False -> {
      let position = int.clamp(local - before.local_ns, 0, span)
      local
      + before_offset
      + { { after_offset - before_offset } * position / span }
    }
  }
}

/// Same-node differences are exact because both instants share a monotonic
/// clock. Cross-node differences subtract calibrated intervals.
pub fn duration(
  from: PositionedEvent,
  to: PositionedEvent,
) -> types.TimeEstimate {
  case from.event.node == to.event.node {
    True ->
      types.ExactTime(
        to.event.local_instant.offset_ns - from.event.local_instant.offset_ns,
      )
    False -> interval_duration(from.time, to.time)
  }
}

fn interval_duration(
  from: types.TimeEstimate,
  to: types.TimeEstimate,
) -> types.TimeEstimate {
  case estimate_bounds(from), estimate_bounds(to) {
    Ok(#(from_center, from_lower, from_upper)),
      Ok(#(to_center, to_lower, to_upper))
    ->
      types.EstimatedTime(
        to_center - from_center,
        to_lower - from_upper,
        to_upper - from_lower,
      )
    Error(reason), _ | _, Error(reason) -> types.TimeUnavailable(reason)
  }
}

/// Return inclusive lower/upper bounds in O(1), or the stated reason when time
/// is unavailable.
pub fn bounds(time: types.TimeEstimate) -> Result(#(Int, Int), String) {
  case estimate_bounds(time) {
    Ok(#(_, lower, upper)) -> Ok(#(lower, upper))
    Error(reason) -> Error(reason)
  }
}

/// Prove strict temporal order only when the two uncertainty intervals do not
/// overlap. Unavailable or overlapping time returns false in O(1).
pub fn definitely_before(
  left: PositionedEvent,
  right: PositionedEvent,
) -> Bool {
  case bounds(left.time), bounds(right.time) {
    Ok(#(_, left_latest)), Ok(#(right_earliest, _)) ->
      left_latest < right_earliest
    _, _ -> False
  }
}

fn estimate_bounds(
  estimate: types.TimeEstimate,
) -> Result(#(Int, Int, Int), String) {
  case estimate {
    types.ExactTime(value) -> Ok(#(value, value, value))
    types.EstimatedTime(value, lower, upper) ->
      case lower <= upper {
        True -> Ok(#(value, lower, upper))
        False -> Error("estimated time lower bound exceeds upper bound")
      }
    types.TimeUnavailable(reason) -> Error(reason)
  }
}

fn find_clock(
  clocks: List(types.NodeClock),
  node: String,
) -> Option(types.NodeClock) {
  case list.find(clocks, fn(clock) { clock.node == node }) {
    Ok(clock) -> Some(clock)
    Error(_) -> None
  }
}

fn unique(items: List(String), accumulator: List(String)) -> List(String) {
  case items {
    [] -> list.reverse(accumulator)
    [item, ..rest] ->
      case list.contains(accumulator, item) {
        True -> unique(rest, accumulator)
        False -> unique(rest, [item, ..accumulator])
      }
  }
}
