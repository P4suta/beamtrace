import beamtrace/types
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

pub type CausalGraph {
  CausalGraph(
    events: List(types.TraceEvent),
    edges: List(types.CausalEdge),
    boundaries: List(types.Boundary),
  )
}

pub type DagError {
  DuplicateEventId(id: String)
  CycleDetected
}

/// A pairing heap keeps Kahn's deterministic ready set logarithmic amortized
/// without requiring target-specific mutable arrays.
type ReadyHeap {
  ReadyEmpty
  ReadyNode(id: String, children: List(ReadyHeap))
}

/// Build only observed process-order, full-serial message, and spawn edges.
/// Node-local clocks are never compared across nodes. All indexes are dict
/// based, so construction and cycle validation are O((n + e) log n).
pub fn build(events: List(types.TraceEvent)) -> Result(CausalGraph, DagError) {
  case index_events(events, dict.new()) {
    Error(id) -> Error(DuplicateEventId(id))
    Ok(event_index) -> {
      let process_edges = process_order_edges(events)
      let #(message_edges, message_boundaries) = message_edges(events)
      let spawn_edges = spawn_edges(events)
      let graph =
        CausalGraph(
          events: events,
          edges: process_edges
            |> list.append(message_edges)
            |> list.append(spawn_edges),
          boundaries: message_boundaries,
        )
      case is_acyclic_indexed(graph, event_index) {
        True -> Ok(graph)
        False -> Error(CycleDetected)
      }
    }
  }
}

pub fn edge_between(
  graph: CausalGraph,
  from: String,
  to: String,
) -> Option(types.CausalEdge) {
  case list.find(graph.edges, fn(edge) { edge.from == from && edge.to == to }) {
    Ok(edge) -> Some(edge)
    Error(_) -> None
  }
}

fn index_events(
  events: List(types.TraceEvent),
  index: Dict(String, types.TraceEvent),
) -> Result(Dict(String, types.TraceEvent), String) {
  case events {
    [] -> Ok(index)
    [event, ..rest] ->
      case dict.has_key(index, event.id) {
        True -> Error(event.id)
        False -> index_events(rest, dict.insert(index, event.id, event))
      }
  }
}

fn process_order_edges(
  events: List(types.TraceEvent),
) -> List(types.CausalEdge) {
  events
  |> group_by_process
  |> dict.values
  |> list.flat_map(fn(process_events) {
    process_events
    |> list.sort(compare_local)
    |> adjacent_process_edges([])
  })
}

fn group_by_process(
  events: List(types.TraceEvent),
) -> Dict(String, List(types.TraceEvent)) {
  list.fold(events, dict.new(), fn(groups, event) {
    let key = process_key(event.process.physical)
    let grouped = case dict.get(groups, key) {
      Ok(existing) -> [event, ..existing]
      Error(_) -> [event]
    }
    dict.insert(groups, key, grouped)
  })
}

fn adjacent_process_edges(
  events: List(types.TraceEvent),
  accumulator: List(types.CausalEdge),
) -> List(types.CausalEdge) {
  case events {
    [left, right, ..rest] ->
      adjacent_process_edges([right, ..rest], [
        types.CausalEdge(left.id, right.id, types.ProcessOrder, types.Exact),
        ..accumulator
      ])
    _ -> list.reverse(accumulator)
  }
}

fn compare_local(
  left: types.TraceEvent,
  right: types.TraceEvent,
) -> order.Order {
  case int.compare(left.local_instant.order, right.local_instant.order) {
    order.Eq ->
      int.compare(left.local_instant.offset_ns, right.local_instant.offset_ns)
    other -> other
  }
}

fn message_edges(
  events: List(types.TraceEvent),
) -> #(List(types.CausalEdge), List(types.Boundary)) {
  let #(sends, receives) = index_messages(events)
  let keys = unique_strings(list.append(dict.keys(sends), dict.keys(receives)))
  list.fold(keys, #([], []), fn(acc, key) {
    let #(edges, boundaries) = acc
    let send_events = dict.get(sends, key) |> result.unwrap([])
    let receive_events = dict.get(receives, key) |> result.unwrap([])
    case send_events, receive_events {
      [send], [received] -> {
        let assert types.Send(_, _, serial) = send.kind
        let evidence = case serial {
          types.SequenceSerial(_, _) -> types.Exact
          types.LegacySerial(_) ->
            types.inferred(
              "legacy_unique_serial",
              "v1 retained only the current seq_trace serial",
              [
                types.EvidenceEvent(send.id),
                types.EvidenceEvent(received.id),
              ],
            )
        }
        #(
          [
            types.CausalEdge(
              send.id,
              received.id,
              types.SequentialMessage(serial),
              evidence,
            ),
            ..edges
          ],
          boundaries,
        )
      }
      [], [_, ..] -> #(
        edges,
        add_boundaries(
          receive_events,
          types.UnobservedState,
          "send was not observed",
          boundaries,
        ),
      )
      [_, ..], [] -> #(
        edges,
        add_boundaries(
          send_events,
          types.ExternalBoundary,
          "receive was not observed",
          boundaries,
        ),
      )
      [_, ..], [_, ..] -> #(
        edges,
        add_boundaries(
          list.append(send_events, receive_events),
          types.UnobservedState,
          "serial collision is ambiguous; no message edge was created",
          boundaries,
        ),
      )
      [], [] -> #(edges, boundaries)
    }
  })
  |> fn(acc) { #(list.reverse(acc.0), list.reverse(acc.1)) }
}

fn index_messages(
  events: List(types.TraceEvent),
) -> #(
  Dict(String, List(types.TraceEvent)),
  Dict(String, List(types.TraceEvent)),
) {
  list.fold(events, #(dict.new(), dict.new()), fn(indexes, event) {
    let #(sends, receives) = indexes
    case event.kind {
      types.Send(to, _, serial) -> #(
        put_event(sends, message_key(event.process.physical, to, serial), event),
        receives,
      )
      types.Received(from, _, serial) -> #(
        sends,
        put_event(
          receives,
          message_key(from, event.process.physical, serial),
          event,
        ),
      )
      _ -> indexes
    }
  })
}

fn put_event(
  index: Dict(String, List(types.TraceEvent)),
  key: String,
  event: types.TraceEvent,
) -> Dict(String, List(types.TraceEvent)) {
  let existing = dict.get(index, key) |> result.unwrap([])
  dict.insert(index, key, [event, ..existing])
}

fn message_key(
  from: types.ProcessRef,
  to: types.ProcessRef,
  serial: types.SequenceSerial,
) -> String {
  process_key(from)
  <> "\u{1f}"
  <> process_key(to)
  <> "\u{1f}"
  <> case serial {
    types.SequenceSerial(previous, current) ->
      "full:" <> int.to_string(previous) <> ":" <> int.to_string(current)
    types.LegacySerial(current) -> "legacy:" <> int.to_string(current)
  }
}

fn add_boundaries(
  events: List(types.TraceEvent),
  kind: types.EdgeKind,
  reason: String,
  accumulator: List(types.Boundary),
) -> List(types.Boundary) {
  list.fold(events, accumulator, fn(boundaries, event) {
    [types.Boundary(event.id, kind, reason), ..boundaries]
  })
}

fn spawn_edges(events: List(types.TraceEvent)) -> List(types.CausalEdge) {
  let first_by_process =
    events
    |> group_by_process
    |> dict.to_list
    |> list.filter_map(fn(entry) {
      let #(key, grouped) = entry
      case list.sort(grouped, compare_local) {
        [first, ..] -> Ok(#(key, first))
        [] -> Error(Nil)
      }
    })
    |> dict.from_list
  list.fold(events, [], fn(edges, event) {
    case event.kind {
      types.Spawn(child, _) ->
        case dict.get(first_by_process, process_key(child)) {
          Ok(child_event) if child_event.id != event.id -> [
            types.CausalEdge(
              event.id,
              child_event.id,
              types.Spawned,
              types.Exact,
            ),
            ..edges
          ]
          _ -> edges
        }
      _ -> edges
    }
  })
  |> list.reverse
}

pub fn is_acyclic(graph: CausalGraph) -> Bool {
  case index_events(graph.events, dict.new()) {
    Error(_) -> False
    Ok(index) -> is_acyclic_indexed(graph, index)
  }
}

fn is_acyclic_indexed(
  graph: CausalGraph,
  events: Dict(String, types.TraceEvent),
) -> Bool {
  let indegree =
    list.fold(dict.keys(events), dict.new(), fn(index, id) {
      dict.insert(index, id, 0)
    })
  let #(adjacency, indegree) =
    list.fold(graph.edges, #(dict.new(), indegree), fn(indexes, edge) {
      let #(adjacency, indegree) = indexes
      case dict.has_key(events, edge.from), dict.has_key(events, edge.to) {
        True, True -> {
          let outgoing = dict.get(adjacency, edge.from) |> result.unwrap([])
          let degree = dict.get(indegree, edge.to) |> result.unwrap(0)
          #(
            dict.insert(adjacency, edge.from, [edge.to, ..outgoing]),
            dict.insert(indegree, edge.to, degree + 1),
          )
        }
        _, _ -> indexes
      }
    })
  let ready =
    indegree
    |> dict.to_list
    |> list.fold(ReadyEmpty, fn(heap, entry) {
      case entry.1 == 0 {
        True -> ready_insert(heap, entry.0, events)
        False -> heap
      }
    })
  kahn(ready, adjacency, indegree, events, 0) == dict.size(events)
}

fn kahn(
  ready: ReadyHeap,
  adjacency: Dict(String, List(String)),
  indegree: Dict(String, Int),
  events: Dict(String, types.TraceEvent),
  visited: Int,
) -> Int {
  case ready_pop(ready, events) {
    Error(_) -> visited
    Ok(#(id, remaining_ready)) -> {
      let outgoing = dict.get(adjacency, id) |> result.unwrap([])
      let #(next_indegree, next_ready) =
        list.fold(outgoing, #(indegree, remaining_ready), fn(state, target) {
          let #(degrees, heap) = state
          let next = { dict.get(degrees, target) |> result.unwrap(0) } - 1
          #(dict.insert(degrees, target, next), case next == 0 {
            True -> ready_insert(heap, target, events)
            False -> heap
          })
        })
      kahn(next_ready, adjacency, next_indegree, events, visited + 1)
    }
  }
}

fn ready_insert(
  heap: ReadyHeap,
  id: String,
  events: Dict(String, types.TraceEvent),
) -> ReadyHeap {
  ready_merge(heap, ReadyNode(id, []), events)
}

fn ready_pop(
  heap: ReadyHeap,
  events: Dict(String, types.TraceEvent),
) -> Result(#(String, ReadyHeap), Nil) {
  case heap {
    ReadyEmpty -> Error(Nil)
    ReadyNode(id, children) -> Ok(#(id, ready_merge_pairs(children, events)))
  }
}

fn ready_merge(
  left: ReadyHeap,
  right: ReadyHeap,
  events: Dict(String, types.TraceEvent),
) -> ReadyHeap {
  case left, right {
    ReadyEmpty, _ -> right
    _, ReadyEmpty -> left
    ReadyNode(left_id, left_children), ReadyNode(right_id, right_children) ->
      case compare_ready(left_id, right_id, events) {
        order.Gt -> ReadyNode(right_id, [left, ..right_children])
        _ -> ReadyNode(left_id, [right, ..left_children])
      }
  }
}

fn ready_merge_pairs(
  heaps: List(ReadyHeap),
  events: Dict(String, types.TraceEvent),
) -> ReadyHeap {
  case heaps {
    [] -> ReadyEmpty
    [one] -> one
    [one, two, ..rest] ->
      ready_merge(
        ready_merge(one, two, events),
        ready_merge_pairs(rest, events),
        events,
      )
  }
}

fn compare_ready(
  left: String,
  right: String,
  events: Dict(String, types.TraceEvent),
) -> order.Order {
  case dict.get(events, left), dict.get(events, right) {
    Ok(left_event), Ok(right_event) ->
      compare_topology_event(left_event, right_event)
    _, _ -> string.compare(left, right)
  }
}

fn compare_topology_event(
  left: types.TraceEvent,
  right: types.TraceEvent,
) -> order.Order {
  case string.compare(left.node, right.node) {
    order.Eq ->
      case
        string.compare(left.process.physical.pid, right.process.physical.pid)
      {
        order.Eq ->
          case
            int.compare(left.local_instant.order, right.local_instant.order)
          {
            order.Eq ->
              case
                int.compare(
                  left.local_instant.offset_ns,
                  right.local_instant.offset_ns,
                )
              {
                order.Eq -> string.compare(left.id, right.id)
                compared -> compared
              }
            compared -> compared
          }
        compared -> compared
      }
    compared -> compared
  }
}

fn process_key(process: types.ProcessRef) -> String {
  process.node <> "\u{0}" <> process.pid
}

fn unique_strings(values: List(String)) -> List(String) {
  values
  |> list.fold(dict.new(), fn(seen, value) { dict.insert(seen, value, True) })
  |> dict.keys
}
