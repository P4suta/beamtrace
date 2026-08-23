// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// A display-only estimate. Causal edges must never be inferred from this
/// offset; seq_trace serials and node-local process order remain authoritative.
pub type ClockEstimate {
  ClockEstimate(node: String, offset_ns: Int, uncertainty_ns: Int)
}

pub type PositionedEvent {
  PositionedEvent(
    event: types.TraceEvent,
    estimated_global_ns: Int,
    uncertainty_ns: Int,
  )
}

pub type MergeResult {
  MergeResult(events: List(PositionedEvent), completeness: types.Completeness)
}

pub fn merge(
  events: List(types.TraceEvent),
  clocks: List(ClockEstimate),
  expected_nodes: List(String),
) -> MergeResult {
  let observed = unique(list.map(events, fn(event) { event.node }), [])
  let missing =
    list.filter(expected_nodes, fn(node) { !list.contains(observed, node) })
  let missing_clocks =
    list.filter(observed, fn(node) { find_clock(clocks, node) == None })
  let completeness = case missing, missing_clocks {
    [_, ..], _ -> types.PartialNode(missing)
    [], [node, ..] ->
      types.InferredCapture("clock estimate unavailable for " <> node)
    [], [] -> types.Complete
  }
  let positioned =
    events
    |> list.map(fn(event) {
      case find_clock(clocks, event.node) {
        Some(clock) ->
          PositionedEvent(
            event,
            event.local_timestamp_ns + clock.offset_ns,
            int.absolute_value(clock.uncertainty_ns),
          )
        None -> PositionedEvent(event, event.local_timestamp_ns, 0)
      }
    })
    |> list.sort(fn(left, right) {
      int.compare(left.estimated_global_ns, right.estimated_global_ns)
    })

  MergeResult(positioned, completeness)
}

pub fn bounds(event: PositionedEvent) -> #(Int, Int) {
  #(
    event.estimated_global_ns - event.uncertainty_ns,
    event.estimated_global_ns + event.uncertainty_ns,
  )
}

pub fn definitely_before(
  left: PositionedEvent,
  right: PositionedEvent,
) -> Bool {
  let #(_, left_latest) = bounds(left)
  let #(right_earliest, _) = bounds(right)
  left_latest < right_earliest
}

fn find_clock(
  clocks: List(ClockEstimate),
  node: String,
) -> Option(ClockEstimate) {
  case clocks {
    [] -> None
    [clock, ..rest] ->
      case clock.node == node {
        True -> Some(clock)
        False -> find_clock(rest, node)
      }
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
