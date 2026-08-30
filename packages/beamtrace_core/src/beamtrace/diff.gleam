//// PID-independent causal alignment and reusable checked preparation.
////
//// `prepare` and `compare_checked` return DAG failures; compatibility
//// `compare` remains total for existing callers. Preparation is O((n + e)
//// log n), caches bounded fingerprint rounds, and can be reused by
//// `compare_prepared`. Results are deterministic on Erlang and JavaScript.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/dag
import beamtrace/types
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const maximum_myers_cells = 250_000

const fingerprint_rounds = 4

/// One aligned, added, removed, changed, or explicitly ambiguous region.
pub type DiffItem {
  Matched(left_id: String, right_id: String, latency_delta: types.TimeEstimate)
  Added(right_id: String)
  Removed(left_id: String)
  Changed(left_id: String, right_id: String, reason: String)
  AmbiguousRegion(
    left_ids: List(String),
    right_ids: List(String),
    reason: String,
  )
}

/// The first divergent pair and its available causal predecessor path.
pub type Divergence {
  Divergence(
    left_id: Option(String),
    right_id: Option(String),
    causal_path: List(String),
  )
}

/// A complete comparison with aggregate counts and first divergence.
pub type DiffReport {
  DiffReport(
    items: List(DiffItem),
    added: Int,
    removed: Int,
    changed: Int,
    ambiguity_count: Int,
    first_divergence: Option(Divergence),
  )
}

type IndexedEvent {
  IndexedEvent(
    index: Int,
    event: types.TraceEvent,
    fingerprint: Int,
    alignment_key: String,
  )
}

// Signatures remain reusable alignment keys, but keeping 100k of them on the
// preparing process heap during DAG refinement makes GC dominate the workload.
// This target-local cache is consumed and deleted before `prepare` returns.
type SignatureCache

/// Reusable analysis of a trace. Construction computes signatures, root
/// origins, the causal graph and its four-round neighborhood fingerprints.
/// The representation is intentionally opaque so it can evolve without
/// exposing analysis internals.
pub opaque type PreparedTrace {
  PreparedTrace(
    events: List(IndexedEvent),
    root_origins: Dict(String, Int),
    causal_incoming: Dict(String, String),
    event_count: Int,
  )
}

type DiffSummary {
  DiffSummary(
    added: Int,
    removed: Int,
    changed: Int,
    ambiguity_count: Int,
    first: Option(DiffItem),
  )
}

type Anchor {
  Anchor(left: Int, right: Int)
}

type Edit {
  Same(left: Int, right: Int)
  Insert(right: Int)
  Delete(left: Int)
}

type DiagonalSearch {
  DiagonalsDone(frontier: Dict(Int, Int), budget: Int)
  DiagonalFound(frontier: Dict(Int, Int), budget: Int)
  DiagonalLimit
}

type SnakeSearch {
  SnakeDone(x: Int, y: Int, budget: Int)
  SnakeLimit
}

/// Compare roots and logical actors by a four-round causal-neighborhood
/// fingerprint. Unique anchors are patience/LIS aligned; gaps use a bounded
/// edit search and remain explicit when no unique answer is defensible.
pub fn compare(
  left: List(types.TraceEvent),
  right: List(types.TraceEvent),
) -> DiffReport {
  case compare_checked(left, right) {
    Ok(report) -> report
    // `compare` predates checked DAG construction. Keep its permissive
    // behaviour for compatibility while new integrations use
    // `compare_checked` (or the top-level `beamtrace` facade).
    Error(_) ->
      compare_prepared(prepare_unchecked(left), prepare_unchecked(right))
  }
}

/// Compare two event lists after validating both causal DAGs.
///
/// The first DAG error is returned instead of silently comparing an invalid
/// trace. Construction is O((n + e) log n); comparison retains the bounded
/// alignment guarantees of `compare`.
pub fn compare_checked(
  left: List(types.TraceEvent),
  right: List(types.TraceEvent),
) -> Result(DiffReport, dag.DagError) {
  case prepare(left) {
    Error(error) -> Error(error)
    Ok(left) ->
      case prepare(right) {
        Error(error) -> Error(error)
        Ok(right) -> Ok(compare_prepared(left, right))
      }
  }
}

/// Analyze and validate a trace once for reuse across comparisons.
///
/// Duplicate event identifiers and causal cycles are returned as `DagError`.
/// Successful construction is O((n + e) log n) and the opaque result may be
/// reused by `compare_prepared` without rebuilding the DAG.
pub fn prepare(
  events: List(types.TraceEvent),
) -> Result(PreparedTrace, dag.DagError) {
  case prepare_with_graph(events) {
    Ok(#(_, prepared)) -> Ok(prepared)
    Error(error) -> Error(error)
  }
}

/// Package-internal bridge used by the top-level facade so the public graph
/// and comparison preparation share one validated DAG construction.
@internal
pub fn prepare_with_graph(
  events: List(types.TraceEvent),
) -> Result(#(dag.CausalGraph, PreparedTrace), dag.DagError) {
  case dag.build_analysis(events) {
    Error(error) -> Error(error)
    Ok(#(graph, incoming, outgoing)) ->
      Ok(#(graph, prepare_from_analysis(events, incoming, outgoing)))
  }
}

fn prepare_unchecked(events: List(types.TraceEvent)) -> PreparedTrace {
  case prepare(events) {
    Ok(prepared) -> prepared
    Error(_) -> prepare_from_analysis(events, dict.new(), dict.new())
  }
}

fn prepare_from_analysis(
  events: List(types.TraceEvent),
  incoming: Dict(String, List(String)),
  outgoing: Dict(String, List(String)),
) -> PreparedTrace {
  let roots = root_signatures(events)
  let #(base, signatures) = base_analysis(events, roots)
  let fingerprints =
    refine(base, incoming, outgoing, dict.keys(base), fingerprint_rounds)
  let causal_incoming = compact_predecessors(incoming)
  let indexed = index_events(events, signatures, fingerprints, 0, [])
  delete_signature_cache(signatures)
  PreparedTrace(
    events: indexed,
    root_origins: root_origins(events),
    causal_incoming: causal_incoming,
    event_count: list.length(events),
  )
}

/// Compare two traces whose reusable analysis has already been prepared.
pub fn compare_prepared(
  left: PreparedTrace,
  right: PreparedTrace,
) -> DiffReport {
  let anchors = patience_anchors(left.events, right.events)
  let items =
    align_around_anchors(
      left.events,
      right.events,
      anchors,
      left.root_origins,
      right.root_origins,
      [],
    )
  let summary = summarize(items, DiffSummary(0, 0, 0, 0, None))
  DiffReport(
    items,
    summary.added,
    summary.removed,
    summary.changed,
    summary.ambiguity_count,
    first_divergence(summary.first, left, right),
  )
}

fn base_analysis(
  events: List(types.TraceEvent),
  roots: Dict(String, String),
) -> #(Dict(String, Int), SignatureCache) {
  let signatures = new_signature_cache()
  #(base_analysis_loop(events, roots, signatures, 0, dict.new()), signatures)
}

fn base_analysis_loop(
  events: List(types.TraceEvent),
  roots: Dict(String, String),
  signatures: SignatureCache,
  position: Int,
  fingerprints: Dict(String, Int),
) -> Dict(String, Int) {
  case events {
    [] -> fingerprints
    [event, ..rest] -> {
      let event_signature = signature(event)
      put_signature(signatures, position, event_signature)
      let root =
        dict.get(roots, event.root_id) |> result.unwrap("root:boundary")
      base_analysis_loop(
        rest,
        roots,
        signatures,
        position + 1,
        dict.insert(
          fingerprints,
          event.id,
          compact_base_fingerprint(root, event_signature),
        ),
      )
    }
  }
}

fn index_events(
  events: List(types.TraceEvent),
  signatures: SignatureCache,
  fingerprints: Dict(String, Int),
  position: Int,
  accumulator: List(IndexedEvent),
) -> List(IndexedEvent) {
  case events {
    [] -> list.reverse(accumulator)
    [event, ..rest] -> {
      let indexed =
        IndexedEvent(
          position,
          event,
          dict.get(fingerprints, event.id) |> result.unwrap(0),
          get_signature(signatures, position),
        )
      index_events(rest, signatures, fingerprints, position + 1, [
        indexed,
        ..accumulator
      ])
    }
  }
}

fn compact_predecessors(
  incoming: Dict(String, List(String)),
) -> Dict(String, String) {
  incoming
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    entry.1
    |> list.last
    |> result.map(fn(predecessor) { #(entry.0, predecessor) })
  })
  |> dict.from_list
}

fn refine(
  fingerprints: Dict(String, Int),
  incoming: Dict(String, List(String)),
  outgoing: Dict(String, List(String)),
  ids: List(String),
  rounds: Int,
) -> Dict(String, Int) {
  case rounds {
    0 -> fingerprints
    _ -> {
      let next = refine_fingerprint_round(fingerprints, incoming, outgoing, ids)
      refine(next, incoming, outgoing, ids, rounds - 1)
    }
  }
}

fn patience_anchors(
  left: List(IndexedEvent),
  right: List(IndexedEvent),
) -> List(Anchor) {
  let left_counts = fingerprint_counts(left)
  let right_counts = fingerprint_counts(right)
  let right_positions =
    list.fold(right, dict.new(), fn(index, item) {
      dict.insert(index, item.fingerprint, item.index)
    })
  let candidates =
    left
    |> list.filter_map(fn(item) {
      case
        dict.get(left_counts, item.fingerprint),
        dict.get(right_counts, item.fingerprint),
        dict.get(right_positions, item.fingerprint)
      {
        Ok(1), Ok(1), Ok(right_index) -> Ok(Anchor(item.index, right_index))
        _, _, _ -> Error(Nil)
      }
    })
  // `left` is already indexed in ascending order, so candidates are already
  // left-sorted. When their right positions are also increasing (the common
  // unchanged/additive case), the complete candidate list is the LIS and no
  // patience frontier dictionaries are needed.
  case anchors_are_increasing(candidates, -1) {
    True -> candidates
    False -> longest_increasing_anchors(candidates)
  }
}

fn anchors_are_increasing(anchors: List(Anchor), previous: Int) -> Bool {
  case anchors {
    [] -> True
    [anchor, ..rest] if anchor.right > previous ->
      anchors_are_increasing(rest, anchor.right)
    _ -> False
  }
}

fn fingerprint_counts(items: List(IndexedEvent)) -> Dict(Int, Int) {
  list.fold(items, dict.new(), fn(counts, item) {
    let count = dict.get(counts, item.fingerprint) |> result.unwrap(0)
    dict.insert(counts, item.fingerprint, count + 1)
  })
}

/// Patience sorting tails are held in an integer-keyed dict, preserving the
/// O(a log a) anchor bound without target-specific arrays.
fn longest_increasing_anchors(candidates: List(Anchor)) -> List(Anchor) {
  let #(tails, predecessors, maximum) =
    list.fold(candidates, #(dict.new(), dict.new(), 0), fn(state, anchor) {
      let #(tails, predecessors, maximum) = state
      let position = lower_bound(tails, anchor.right, 1, maximum + 1)
      let predecessor = case position > 1, dict.get(tails, position - 1) {
        True, Ok(previous) -> previous.left
        _, _ -> -1
      }
      #(
        dict.insert(tails, position, anchor),
        dict.insert(predecessors, anchor.left, predecessor),
        int.max(maximum, position),
      )
    })
  case dict.get(tails, maximum) {
    Error(_) -> []
    Ok(last) -> {
      let by_left =
        list.fold(candidates, dict.new(), fn(index, anchor) {
          dict.insert(index, anchor.left, anchor)
        })
      reconstruct_anchors(last, predecessors, by_left, [])
    }
  }
}

fn lower_bound(
  tails: Dict(Int, Anchor),
  right: Int,
  low: Int,
  high: Int,
) -> Int {
  case low >= high {
    True -> low
    False -> {
      let middle = { low + high } / 2
      case dict.get(tails, middle) {
        Ok(anchor) if anchor.right < right ->
          lower_bound(tails, right, middle + 1, high)
        _ -> lower_bound(tails, right, low, middle)
      }
    }
  }
}

fn reconstruct_anchors(
  current: Anchor,
  predecessors: Dict(Int, Int),
  candidates: Dict(Int, Anchor),
  accumulator: List(Anchor),
) -> List(Anchor) {
  case dict.get(predecessors, current.left) {
    Ok(previous) if previous >= 0 ->
      case dict.get(candidates, previous) {
        Ok(anchor) ->
          reconstruct_anchors(anchor, predecessors, candidates, [
            current,
            ..accumulator
          ])
        Error(_) -> [current, ..accumulator]
      }
    _ -> [current, ..accumulator]
  }
}

fn align_around_anchors(
  left: List(IndexedEvent),
  right: List(IndexedEvent),
  anchors: List(Anchor),
  left_origins: Dict(String, Int),
  right_origins: Dict(String, Int),
  accumulator: List(DiffItem),
) -> List(DiffItem) {
  case anchors {
    [] ->
      accumulator
      |> prepend_items(align_gap(left, right, left_origins, right_origins))
      |> list.reverse
    [anchor, ..rest] -> {
      let #(left_gap, left_at_anchor) = take_before(left, anchor.left, [])
      let #(right_gap, right_at_anchor) = take_before(right, anchor.right, [])
      let before = align_gap(left_gap, right_gap, left_origins, right_origins)
      case left_at_anchor, right_at_anchor {
        [left_anchor, ..left_rest], [right_anchor, ..right_rest]
          if left_anchor.index == anchor.left
          && right_anchor.index == anchor.right
        ->
          align_around_anchors(
            left_rest,
            right_rest,
            rest,
            left_origins,
            right_origins,
            [
              matched(left_anchor, right_anchor, left_origins, right_origins),
              ..prepend_items(accumulator, before)
            ],
          )
        _, _ -> prepend_items(accumulator, before) |> list.reverse
      }
    }
  }
}

/// Add forward-ordered items to an accumulator held in reverse order. This
/// keeps patience alignment linear after the O(a log a) anchor search.
fn prepend_items(reversed: List(item), items: List(item)) -> List(item) {
  list.fold(items, reversed, fn(accumulator, item) { [item, ..accumulator] })
}

fn take_before(
  items: List(IndexedEvent),
  end: Int,
  accumulator: List(IndexedEvent),
) -> #(List(IndexedEvent), List(IndexedEvent)) {
  case items {
    [item, ..rest] if item.index < end ->
      take_before(rest, end, [item, ..accumulator])
    _ -> #(list.reverse(accumulator), items)
  }
}

fn align_gap(
  left: List(IndexedEvent),
  right: List(IndexedEvent),
  left_origins: Dict(String, Int),
  right_origins: Dict(String, Int),
) -> List(DiffItem) {
  case left, right {
    [], [] -> []
    [], _ -> list.map(right, fn(item) { Added(item.event.id) })
    _, [] -> list.map(left, fn(item) { Removed(item.event.id) })
    _, _ -> {
      let cells = list.length(left) * list.length(right)
      case cells > maximum_myers_cells {
        True -> [ambiguous(left, right, "bounded Myers cell limit exceeded")]
        False ->
          case repeated_common_alignment_key(left, right) {
            True -> [
              ambiguous(
                left,
                right,
                "repeated logical signatures do not have a unique alignment",
              ),
            ]
            False ->
              case bounded_myers(left, right, left_origins, right_origins) {
                Ok(items) -> items
                Error(_) -> [
                  ambiguous(
                    left,
                    right,
                    "bounded Myers operation limit exceeded",
                  ),
                ]
              }
          }
      }
    }
  }
}

fn bounded_myers(
  left: List(IndexedEvent),
  right: List(IndexedEvent),
  left_origins: Dict(String, Int),
  right_origins: Dict(String, Int),
) -> Result(List(DiffItem), Nil) {
  let left_index = event_position_index(left)
  let right_index = event_position_index(right)
  use edits <- result.try(myers_search(
    left_index,
    right_index,
    list.length(left),
    list.length(right),
    0,
    dict.insert(dict.new(), 1, 0),
    [],
    maximum_myers_cells,
  ))
  Ok(
    edits_to_items(
      edits,
      left_index,
      right_index,
      left_origins,
      right_origins,
      [],
    ),
  )
}

fn myers_search(
  left: Dict(Int, IndexedEvent),
  right: Dict(Int, IndexedEvent),
  left_length: Int,
  right_length: Int,
  distance: Int,
  frontier: Dict(Int, Int),
  trace: List(Dict(Int, Int)),
  budget: Int,
) -> Result(List(Edit), Nil) {
  case distance > left_length + right_length || budget <= 0 {
    True -> Error(Nil)
    False ->
      case
        walk_diagonals(
          left,
          right,
          left_length,
          right_length,
          distance,
          0 - distance,
          frontier,
          dict.new(),
          budget,
        )
      {
        DiagonalLimit -> Error(Nil)
        DiagonalFound(_, _) ->
          Ok(
            backtrack_edits(
              distance,
              [frontier, ..trace],
              left_length,
              right_length,
              [],
            ),
          )
        DiagonalsDone(next, remaining) ->
          myers_search(
            left,
            right,
            left_length,
            right_length,
            distance + 1,
            next,
            [frontier, ..trace],
            remaining,
          )
      }
  }
}

fn walk_diagonals(
  left: Dict(Int, IndexedEvent),
  right: Dict(Int, IndexedEvent),
  left_length: Int,
  right_length: Int,
  distance: Int,
  diagonal: Int,
  previous: Dict(Int, Int),
  next: Dict(Int, Int),
  budget: Int,
) -> DiagonalSearch {
  case diagonal > distance, budget <= 0 {
    True, _ -> DiagonalsDone(next, budget)
    _, True -> DiagonalLimit
    False, False -> {
      let move_down =
        diagonal == 0 - distance
        || {
          diagonal != distance
          && frontier_x(previous, diagonal - 1)
          < frontier_x(previous, diagonal + 1)
        }
      let start_x = case move_down {
        True -> frontier_x(previous, diagonal + 1)
        False -> frontier_x(previous, diagonal - 1) + 1
      }
      let start_y = start_x - diagonal
      case
        snake(
          left,
          right,
          left_length,
          right_length,
          start_x,
          start_y,
          budget - 1,
        )
      {
        SnakeLimit -> DiagonalLimit
        SnakeDone(x, y, remaining) -> {
          let advanced = dict.insert(next, diagonal, x)
          case x >= left_length && y >= right_length {
            True -> DiagonalFound(advanced, remaining)
            False ->
              walk_diagonals(
                left,
                right,
                left_length,
                right_length,
                distance,
                diagonal + 2,
                previous,
                advanced,
                remaining,
              )
          }
        }
      }
    }
  }
}

fn snake(
  left: Dict(Int, IndexedEvent),
  right: Dict(Int, IndexedEvent),
  left_length: Int,
  right_length: Int,
  x: Int,
  y: Int,
  budget: Int,
) -> SnakeSearch {
  case x < left_length && y < right_length, budget <= 0 {
    False, _ -> SnakeDone(x, y, budget)
    True, True -> SnakeLimit
    True, False ->
      case dict.get(left, x), dict.get(right, y) {
        Ok(left_item), Ok(right_item)
          if left_item.alignment_key == right_item.alignment_key
        ->
          snake(
            left,
            right,
            left_length,
            right_length,
            x + 1,
            y + 1,
            budget - 1,
          )
        _, _ -> SnakeDone(x, y, budget - 1)
      }
  }
}

fn frontier_x(frontier: Dict(Int, Int), diagonal: Int) -> Int {
  dict.get(frontier, diagonal) |> result.unwrap(0)
}

fn backtrack_edits(
  distance: Int,
  trace: List(Dict(Int, Int)),
  x: Int,
  y: Int,
  accumulator: List(Edit),
) -> List(Edit) {
  case trace {
    [] -> accumulator
    [frontier, ..rest] -> {
      let diagonal = x - y
      let previous_diagonal = case
        diagonal == 0 - distance
        || {
          diagonal != distance
          && frontier_x(frontier, diagonal - 1)
          < frontier_x(frontier, diagonal + 1)
        }
      {
        True -> diagonal + 1
        False -> diagonal - 1
      }
      let previous_x = frontier_x(frontier, previous_diagonal)
      let previous_y = previous_x - previous_diagonal
      let with_snake =
        backtrack_snake(x, y, previous_x, previous_y, accumulator)
      case distance <= 0 {
        True -> with_snake
        False -> {
          let with_edit = case previous_diagonal == diagonal + 1 {
            True -> [Insert(previous_y), ..with_snake]
            False -> [Delete(previous_x), ..with_snake]
          }
          backtrack_edits(distance - 1, rest, previous_x, previous_y, with_edit)
        }
      }
    }
  }
}

fn backtrack_snake(
  x: Int,
  y: Int,
  previous_x: Int,
  previous_y: Int,
  accumulator: List(Edit),
) -> List(Edit) {
  case x > previous_x && y > previous_y {
    True ->
      backtrack_snake(x - 1, y - 1, previous_x, previous_y, [
        Same(x - 1, y - 1),
        ..accumulator
      ])
    False -> accumulator
  }
}

fn edits_to_items(
  edits: List(Edit),
  left: Dict(Int, IndexedEvent),
  right: Dict(Int, IndexedEvent),
  left_origins: Dict(String, Int),
  right_origins: Dict(String, Int),
  accumulator: List(DiffItem),
) -> List(DiffItem) {
  case edits {
    [] -> list.reverse(accumulator)
    [Same(left_position, right_position), ..rest] ->
      case dict.get(left, left_position), dict.get(right, right_position) {
        Ok(left_item), Ok(right_item) -> {
          let item = case left_item.fingerprint == right_item.fingerprint {
            True -> matched(left_item, right_item, left_origins, right_origins)
            False ->
              Changed(
                left_item.event.id,
                right_item.event.id,
                "causal neighborhood differs",
              )
          }
          edits_to_items(rest, left, right, left_origins, right_origins, [
            item,
            ..accumulator
          ])
        }
        _, _ ->
          edits_to_items(
            rest,
            left,
            right,
            left_origins,
            right_origins,
            accumulator,
          )
      }
    [Insert(position), ..rest] ->
      case dict.get(right, position) {
        Ok(item) ->
          edits_to_items(rest, left, right, left_origins, right_origins, [
            Added(item.event.id),
            ..accumulator
          ])
        Error(_) ->
          edits_to_items(
            rest,
            left,
            right,
            left_origins,
            right_origins,
            accumulator,
          )
      }
    [Delete(position), ..rest] ->
      case dict.get(left, position) {
        Ok(item) ->
          edits_to_items(rest, left, right, left_origins, right_origins, [
            Removed(item.event.id),
            ..accumulator
          ])
        Error(_) ->
          edits_to_items(
            rest,
            left,
            right,
            left_origins,
            right_origins,
            accumulator,
          )
      }
  }
}

fn event_position_index(events: List(IndexedEvent)) -> Dict(Int, IndexedEvent) {
  events
  |> list.index_map(fn(event, index) { #(index, event) })
  |> dict.from_list
}

fn matched(
  left: IndexedEvent,
  right: IndexedEvent,
  left_origins: Dict(String, Int),
  right_origins: Dict(String, Int),
) -> DiffItem {
  Matched(
    left.event.id,
    right.event.id,
    latency_delta(left.event, right.event, left_origins, right_origins),
  )
}

fn latency_delta(
  left: types.TraceEvent,
  right: types.TraceEvent,
  left_origins: Dict(String, Int),
  right_origins: Dict(String, Int),
) -> types.TimeEstimate {
  case
    dict.get(left_origins, root_key(left)),
    dict.get(right_origins, root_key(right))
  {
    Ok(left_origin), Ok(right_origin) ->
      types.ExactTime(
        { right.local_instant.offset_ns - right_origin }
        - { left.local_instant.offset_ns - left_origin },
      )
    _, _ -> types.TimeUnavailable("same-node root origin was not observed")
  }
}

fn root_origins(events: List(types.TraceEvent)) -> Dict(String, Int) {
  list.fold(events, dict.new(), fn(index, event) {
    let key = root_key(event)
    case dict.get(index, key) {
      Ok(value) ->
        dict.insert(index, key, int.min(value, event.local_instant.offset_ns))
      Error(_) -> dict.insert(index, key, event.local_instant.offset_ns)
    }
  })
}

fn root_key(event: types.TraceEvent) -> String {
  event.root_id <> "\u{0}" <> event.node
}

fn repeated_common_alignment_key(
  left: List(IndexedEvent),
  right: List(IndexedEvent),
) -> Bool {
  let left_counts = alignment_key_counts(left)
  let right_counts = alignment_key_counts(right)
  list.any(dict.to_list(left_counts), fn(entry) {
    case dict.get(right_counts, entry.0) {
      Ok(count) -> entry.1 > 1 || count > 1
      Error(_) -> False
    }
  })
}

fn alignment_key_counts(items: List(IndexedEvent)) -> Dict(String, Int) {
  list.fold(items, dict.new(), fn(counts, item) {
    let count = dict.get(counts, item.alignment_key) |> result.unwrap(0)
    dict.insert(counts, item.alignment_key, count + 1)
  })
}

fn ambiguous(
  left: List(IndexedEvent),
  right: List(IndexedEvent),
  reason: String,
) -> DiffItem {
  AmbiguousRegion(
    list.map(left, fn(item) { item.event.id }),
    list.map(right, fn(item) { item.event.id }),
    reason,
  )
}

fn summarize(items: List(DiffItem), summary: DiffSummary) -> DiffSummary {
  case items {
    [] -> summary
    [item, ..rest] -> {
      let next = case item {
        Matched(_, _, _) -> summary
        Added(_) ->
          DiffSummary(
            ..summary,
            added: summary.added + 1,
            first: remember_first(summary.first, item),
          )
        Removed(_) ->
          DiffSummary(
            ..summary,
            removed: summary.removed + 1,
            first: remember_first(summary.first, item),
          )
        Changed(_, _, _) ->
          DiffSummary(
            ..summary,
            changed: summary.changed + 1,
            first: remember_first(summary.first, item),
          )
        AmbiguousRegion(_, _, _) ->
          DiffSummary(
            ..summary,
            ambiguity_count: summary.ambiguity_count + 1,
            first: remember_first(summary.first, item),
          )
      }
      summarize(rest, next)
    }
  }
}

fn remember_first(first: Option(DiffItem), item: DiffItem) -> Option(DiffItem) {
  case first {
    None -> Some(item)
    Some(_) -> first
  }
}

fn first_divergence(
  item: Option(DiffItem),
  left: PreparedTrace,
  right: PreparedTrace,
) -> Option(Divergence) {
  case item {
    None -> None
    Some(Matched(_, _, _)) -> None
    Some(Added(right_id)) ->
      Some(Divergence(None, Some(right_id), causal_path(right, right_id)))
    Some(Removed(left_id)) ->
      Some(Divergence(Some(left_id), None, causal_path(left, left_id)))
    Some(Changed(left_id, right_id, _)) ->
      Some(Divergence(Some(left_id), Some(right_id), causal_path(left, left_id)))
    Some(AmbiguousRegion(left_ids, right_ids, _)) -> {
      let left_id =
        list.first(left_ids) |> result.map(Some) |> result.unwrap(None)
      let right_id =
        list.first(right_ids) |> result.map(Some) |> result.unwrap(None)
      Some(
        Divergence(left_id, right_id, case left_id {
          Some(id) -> causal_path(left, id)
          None ->
            case right_id {
              Some(id) -> causal_path(right, id)
              None -> []
            }
        }),
      )
    }
  }
}

fn causal_path(trace: PreparedTrace, target: String) -> List(String) {
  causal_predecessors(trace.causal_incoming, target, [], trace.event_count)
}

fn causal_predecessors(
  incoming: Dict(String, String),
  current: String,
  accumulator: List(String),
  remaining: Int,
) -> List(String) {
  case remaining <= 0 {
    True -> [current, ..accumulator]
    False ->
      case dict.get(incoming, current) {
        Ok(predecessor) ->
          causal_predecessors(
            incoming,
            predecessor,
            [current, ..accumulator],
            remaining - 1,
          )
        Error(_) -> [current, ..accumulator]
      }
  }
}

fn root_signatures(events: List(types.TraceEvent)) -> Dict(String, String) {
  list.fold(events, dict.new(), fn(index, event) {
    case event.kind {
      types.Root(_, _) ->
        dict.insert(index, event.root_id, kind_signature(event.kind))
      _ -> index
    }
  })
}

/// Produce the PID- and clock-origin-independent event alignment key in O(event
/// metadata size). It is deterministic and cannot fail on either target.
pub fn signature(event: types.TraceEvent) -> String {
  actor_signature(event.process) <> "|" <> kind_signature(event.kind)
}

fn actor_signature(process: types.ProcessIdentity) -> String {
  case process.logical {
    Some(actor) -> actor.id
    None -> evidence_actor(process.evidence)
  }
}

fn evidence_actor(evidence: List(types.IdentityEvidence)) -> String {
  case evidence {
    [] -> "<unresolved-actor>"
    [types.RegisteredName(name), ..] -> "registered:" <> name
    [types.ProcessLabel(label), ..] -> "label:" <> label
    [types.SupervisorChildId(id), ..] -> "child:" <> id
    [_, ..rest] -> evidence_actor(rest)
  }
}

fn kind_signature(kind: types.TraceEventKind) -> String {
  case kind {
    types.Root(types.Mfa(module_, function_, arity), arguments) ->
      "root:"
      <> module_
      <> ":"
      <> function_
      <> "/"
      <> int.to_string(arity)
      <> ":"
      <> views_signature(arguments)
    types.Send(_, message, _) -> "send:" <> view_signature(message)
    types.Received(_, message, _) -> "receive:" <> view_signature(message)
    types.Spawn(_, types.Mfa(module_, function_, arity)) ->
      "spawn:" <> module_ <> ":" <> function_ <> "/" <> int.to_string(arity)
    types.Exit(reason) -> "exit:" <> view_signature(reason)
    types.Register(name) -> "register:" <> name
    types.Link(_) -> "link"
    types.Metric(name, _) -> "metric:" <> name
    types.SystemSignal(name, _) -> "system:" <> name
    types.Gap(_, reason) -> "gap:" <> reason
    types.Stop(reason) -> "stop:" <> reason
  }
}

fn views_signature(views: List(types.TermView)) -> String {
  views |> list.map(view_signature) |> string.join(",")
}

fn view_signature(view: types.TermView) -> String {
  case view {
    types.Hidden -> "hidden"
    types.Atom(name) -> "atom:" <> name
    types.Tag(name) -> "tag:" <> name
    types.Tuple(items) -> "tuple(" <> views_signature(items) <> ")"
    types.Constructor(name, fields) ->
      "constructor:" <> name <> "(" <> views_signature(fields) <> ")"
    types.ListView(length, items) ->
      "list:" <> int.to_string(length) <> "(" <> views_signature(items) <> ")"
    types.MapView(size, entries) ->
      "map:" <> int.to_string(size) <> "(" <> entries_signature(entries) <> ")"
    types.BinaryMetadata(bytes, _, _) -> "binary:" <> int.to_string(bytes)
    types.Scalar(kind, _, _) -> "scalar:" <> kind
    types.Redacted(reason) -> "redacted:" <> reason
  }
}

fn entries_signature(
  entries: List(#(types.TermView, types.TermView)),
) -> String {
  entries
  |> list.map(fn(entry) {
    view_signature(entry.0) <> "=" <> view_signature(entry.1)
  })
  |> string.join(",")
}

@external(erlang, "beamtrace_diff_ffi", "compact_base")
@external(javascript, "../beamtrace_diff_ffi.mjs", "compactBase")
fn compact_base_fingerprint(root: String, event_signature: String) -> Int

@external(erlang, "beamtrace_diff_ffi", "refine_round")
@external(javascript, "../beamtrace_diff_ffi.mjs", "refineRound")
fn refine_fingerprint_round(
  fingerprints: Dict(String, Int),
  incoming: Dict(String, List(String)),
  outgoing: Dict(String, List(String)),
  ids: List(String),
) -> Dict(String, Int)

@external(erlang, "beamtrace_diff_ffi", "signature_cache_new")
@external(javascript, "../beamtrace_diff_ffi.mjs", "signatureCacheNew")
fn new_signature_cache() -> SignatureCache

@external(erlang, "beamtrace_diff_ffi", "signature_cache_put")
@external(javascript, "../beamtrace_diff_ffi.mjs", "signatureCachePut")
fn put_signature(cache: SignatureCache, position: Int, signature: String) -> Nil

@external(erlang, "beamtrace_diff_ffi", "signature_cache_get")
@external(javascript, "../beamtrace_diff_ffi.mjs", "signatureCacheGet")
fn get_signature(cache: SignatureCache, position: Int) -> String

@external(erlang, "beamtrace_diff_ffi", "signature_cache_delete")
@external(javascript, "../beamtrace_diff_ffi.mjs", "signatureCacheDelete")
fn delete_signature_cache(cache: SignatureCache) -> Nil
