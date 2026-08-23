import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

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

/// Builds only edges supported by an observed process order, spawn event, or
/// seq_trace serial. A missing counterpart becomes a boundary marker.
pub fn build(events: List(types.TraceEvent)) -> Result(CausalGraph, DagError) {
  case duplicate_id(events, []) {
    Some(id) -> Error(DuplicateEventId(id))
    None -> {
      let ordered =
        list.sort(events, fn(left, right) {
          int.compare(left.local_timestamp_ns, right.local_timestamp_ns)
        })
      let process_edges = process_order_edges(ordered, [], [])
      let #(message_edges, boundaries) = message_edges(events, events, [], [])
      let spawn_edges = spawn_edges(events, events, [])
      let graph =
        CausalGraph(
          events: events,
          edges: process_edges
            |> list.append(message_edges)
            |> list.append(spawn_edges),
          boundaries: boundaries,
        )

      case is_acyclic(graph) {
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
  find_edge(graph.edges, from, to)
}

fn find_edge(
  edges: List(types.CausalEdge),
  from: String,
  to: String,
) -> Option(types.CausalEdge) {
  case edges {
    [] -> None
    [edge, ..rest] ->
      case edge.from == from && edge.to == to {
        True -> Some(edge)
        False -> find_edge(rest, from, to)
      }
  }
}

fn duplicate_id(
  events: List(types.TraceEvent),
  seen: List(String),
) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case list.contains(seen, event.id) {
        True -> Some(event.id)
        False -> duplicate_id(rest, [event.id, ..seen])
      }
  }
}

fn process_order_edges(
  events: List(types.TraceEvent),
  previous: List(#(types.ProcessRef, types.TraceEvent)),
  edges: List(types.CausalEdge),
) -> List(types.CausalEdge) {
  case events {
    [] -> list.reverse(edges)
    [event, ..rest] -> {
      let prior = find_previous(previous, event.process.physical)
      let next_edges = case prior {
        Some(prior) -> [
          types.CausalEdge(
            from: prior.id,
            to: event.id,
            kind: types.ProcessOrder,
            evidence: types.Exact,
          ),
          ..edges
        ]
        None -> edges
      }
      process_order_edges(
        rest,
        put_previous(previous, event.process.physical, event),
        next_edges,
      )
    }
  }
}

fn find_previous(
  previous: List(#(types.ProcessRef, types.TraceEvent)),
  process: types.ProcessRef,
) -> Option(types.TraceEvent) {
  case previous {
    [] -> None
    [#(candidate, event), ..rest] ->
      case candidate == process {
        True -> Some(event)
        False -> find_previous(rest, process)
      }
  }
}

fn put_previous(
  previous: List(#(types.ProcessRef, types.TraceEvent)),
  process: types.ProcessRef,
  event: types.TraceEvent,
) -> List(#(types.ProcessRef, types.TraceEvent)) {
  case previous {
    [] -> [#(process, event)]
    [#(candidate, _), ..rest] if candidate == process -> [
      #(process, event),
      ..rest
    ]
    [entry, ..rest] -> [entry, ..put_previous(rest, process, event)]
  }
}

fn message_edges(
  remaining: List(types.TraceEvent),
  all_events: List(types.TraceEvent),
  edges: List(types.CausalEdge),
  boundaries: List(types.Boundary),
) -> #(List(types.CausalEdge), List(types.Boundary)) {
  case remaining {
    [] -> #(list.reverse(edges), list.reverse(boundaries))
    [event, ..rest] ->
      case event.kind {
        types.Send(to, _, serial) ->
          case find_receive(all_events, event.process.physical, to, serial) {
            Some(receive_event) ->
              message_edges(
                rest,
                all_events,
                [
                  types.CausalEdge(
                    from: event.id,
                    to: receive_event.id,
                    kind: types.SequentialMessage(serial),
                    evidence: types.Exact,
                  ),
                  ..edges
                ],
                boundaries,
              )
            None ->
              message_edges(rest, all_events, edges, [
                types.Boundary(
                  event.id,
                  types.ExternalBoundary,
                  "receive was not observed",
                ),
                ..boundaries
              ])
          }
        types.Received(from, _, serial) ->
          case
            find_send_anywhere(all_events, from, event.process.physical, serial)
          {
            Some(_) -> message_edges(rest, all_events, edges, boundaries)
            None ->
              message_edges(rest, all_events, edges, [
                types.Boundary(
                  event.id,
                  types.UnobservedState,
                  "send was not observed",
                ),
                ..boundaries
              ])
          }
        _ -> message_edges(rest, all_events, edges, boundaries)
      }
  }
}

fn find_receive(
  events: List(types.TraceEvent),
  from: types.ProcessRef,
  to: types.ProcessRef,
  serial: Int,
) -> Option(types.TraceEvent) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind {
        types.Received(candidate_from, _, candidate_serial)
          if candidate_from == from
          && event.process.physical == to
          && candidate_serial == serial
        -> Some(event)
        _ -> find_receive(rest, from, to, serial)
      }
  }
}

fn find_send_anywhere(
  events: List(types.TraceEvent),
  from: types.ProcessRef,
  to: types.ProcessRef,
  serial: Int,
) -> Option(types.TraceEvent) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind {
        types.Send(candidate_to, _, candidate_serial)
          if event.process.physical == from
          && candidate_to == to
          && candidate_serial == serial
        -> Some(event)
        _ -> find_send_anywhere(rest, from, to, serial)
      }
  }
}

fn spawn_edges(
  remaining: List(types.TraceEvent),
  all_events: List(types.TraceEvent),
  edges: List(types.CausalEdge),
) -> List(types.CausalEdge) {
  case remaining {
    [] -> list.reverse(edges)
    [event, ..rest] ->
      case event.kind {
        types.Spawn(child, _) ->
          case first_event_for(all_events, child, event.local_timestamp_ns) {
            Some(child_event) ->
              spawn_edges(rest, all_events, [
                types.CausalEdge(
                  from: event.id,
                  to: child_event.id,
                  kind: types.Spawned,
                  evidence: types.Exact,
                ),
                ..edges
              ])
            None -> spawn_edges(rest, all_events, edges)
          }
        _ -> spawn_edges(rest, all_events, edges)
      }
  }
}

fn first_event_for(
  events: List(types.TraceEvent),
  process: types.ProcessRef,
  after_ns: Int,
) -> Option(types.TraceEvent) {
  case events {
    [] -> None
    [event, ..rest] ->
      case
        event.process.physical == process
        && event.local_timestamp_ns >= after_ns
      {
        True -> Some(event)
        False -> first_event_for(rest, process, after_ns)
      }
  }
}

pub fn is_acyclic(graph: CausalGraph) -> Bool {
  kahn(list.map(graph.events, fn(event) { event.id }), graph.edges)
}

fn kahn(ids: List(String), edges: List(types.CausalEdge)) -> Bool {
  case ids {
    [] -> True
    _ -> {
      let roots = list.filter(ids, fn(id) { !has_incoming(id, ids, edges) })
      case roots {
        [] -> False
        _ -> {
          let remaining = list.filter(ids, fn(id) { !list.contains(roots, id) })
          kahn(remaining, edges)
        }
      }
    }
  }
}

fn has_incoming(
  id: String,
  remaining: List(String),
  edges: List(types.CausalEdge),
) -> Bool {
  list.any(edges, fn(edge) {
    edge.to == id && list.contains(remaining, edge.from)
  })
}
