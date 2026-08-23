// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{None, Some}

pub type FindingKind {
  HotSender
  FanIn
  QueueWait
  DanglingCall
  ReplyTimeout
  CrashChain
  SpawnChurn
  CriticalPath
}

pub type Finding {
  Finding(
    kind: FindingKind,
    summary: String,
    evidence: types.Evidence,
    event_ids: List(String),
    value: Int,
  )
}

pub fn hot_senders(
  events: List(types.TraceEvent),
  minimum_messages minimum_messages: Int,
) -> List(Finding) {
  sender_keys(events, [])
  |> list.filter_map(fn(key) {
    let matching = list.filter(events, fn(event) { is_send_by(event, key) })
    let count = list.length(matching)
    case count >= minimum_messages {
      False -> Error(Nil)
      True ->
        Ok(Finding(
          kind: HotSender,
          summary: key <> " sent " <> int.to_string(count) <> " messages",
          evidence: types.Exact,
          event_ids: list.map(matching, fn(event) { event.id }),
          value: count,
        ))
    }
  })
}

pub fn fan_in(
  events: List(types.TraceEvent),
  minimum_senders minimum_senders: Int,
) -> List(Finding) {
  receiver_keys(events, [])
  |> list.filter_map(fn(key) {
    let matching = list.filter(events, fn(event) { is_received_by(event, key) })
    let senders = received_senders(matching, [])
    let count = list.length(senders)
    case count >= minimum_senders {
      False -> Error(Nil)
      True ->
        Ok(Finding(
          kind: FanIn,
          summary: key
            <> " received from "
            <> int.to_string(count)
            <> " senders",
          evidence: types.Exact,
          event_ids: list.map(matching, fn(event) { event.id }),
          value: count,
        ))
    }
  })
}

pub fn queue_waits(
  events: List(types.TraceEvent),
  minimum_ns minimum_ns: Int,
) -> List(Finding) {
  queue_waits_loop(events, events, minimum_ns, []) |> list.reverse
}

fn queue_waits_loop(
  remaining: List(types.TraceEvent),
  all: List(types.TraceEvent),
  minimum_ns: Int,
  accumulator: List(Finding),
) -> List(Finding) {
  case remaining {
    [] -> accumulator
    [event, ..rest] ->
      case matching_receive(event, all) {
        Error(_) -> queue_waits_loop(rest, all, minimum_ns, accumulator)
        Ok(received) -> {
          let duration = received.local_timestamp_ns - event.local_timestamp_ns
          let accumulator = case duration >= minimum_ns && duration >= 0 {
            False -> accumulator
            True -> [
              Finding(
                kind: QueueWait,
                summary: "message waited "
                  <> int.to_string(duration)
                  <> "ns before receive",
                evidence: types.Exact,
                event_ids: [event.id, received.id],
                value: duration,
              ),
              ..accumulator
            ]
          }
          queue_waits_loop(rest, all, minimum_ns, accumulator)
        }
      }
  }
}

pub fn dangling_calls(
  events: List(types.TraceEvent),
  now_ns now_ns: Int,
  timeout_ns timeout_ns: Int,
) -> List(Finding) {
  events
  |> list.filter_map(fn(event) {
    case
      call_endpoints(event),
      now_ns - event.local_timestamp_ns >= timeout_ns
    {
      Ok(#(caller, callee)), True ->
        case
          has_reverse_reply(events, caller, callee, event.local_timestamp_ns)
        {
          True -> Error(Nil)
          False ->
            Ok(Finding(
              kind: DanglingCall,
              summary: "call has no observed reply after "
                <> int.to_string(now_ns - event.local_timestamp_ns)
                <> "ns",
              evidence: types.inferred(
                "no reverse reply was observed before timeout",
                0.85,
              ),
              event_ids: [event.id],
              value: now_ns - event.local_timestamp_ns,
            ))
        }
      _, _ -> Error(Nil)
    }
  })
}

/// Group a crash and subsequent supervisor spawn only when the new physical
/// PID is later observed with the same logical actor identity. The temporal
/// association is intentionally retained as inferred evidence.
pub fn restart_chains(
  events: List(types.TraceEvent),
  maximum_gap_ns maximum_gap_ns: Int,
) -> List(Finding) {
  restart_chains_loop(events, events, maximum_gap_ns, []) |> list.reverse
}

fn restart_chains_loop(
  remaining: List(types.TraceEvent),
  all: List(types.TraceEvent),
  maximum_gap_ns: Int,
  accumulator: List(Finding),
) -> List(Finding) {
  case remaining {
    [] -> accumulator
    [event, ..rest] ->
      case event.kind, event.process.logical {
        types.Exit(_), Some(actor) ->
          case restart_after(event, actor, rest, all, maximum_gap_ns) {
            Ok(finding) ->
              restart_chains_loop(rest, all, maximum_gap_ns, [
                finding,
                ..accumulator
              ])
            Error(_) ->
              restart_chains_loop(rest, all, maximum_gap_ns, accumulator)
          }
        _, _ -> restart_chains_loop(rest, all, maximum_gap_ns, accumulator)
      }
  }
}

fn restart_after(
  exited: types.TraceEvent,
  actor: types.LogicalActor,
  candidates: List(types.TraceEvent),
  all: List(types.TraceEvent),
  maximum_gap_ns: Int,
) -> Result(Finding, Nil) {
  case candidates {
    [] -> Error(Nil)
    [candidate, ..rest] ->
      case candidate.kind {
        types.Spawn(child, _) -> {
          let gap = candidate.local_timestamp_ns - exited.local_timestamp_ns
          case gap >= 0 && gap <= maximum_gap_ns {
            False -> restart_after(exited, actor, rest, all, maximum_gap_ns)
            True ->
              case
                observed_as_actor(
                  all,
                  child,
                  actor,
                  candidate.local_timestamp_ns,
                )
              {
                Error(_) ->
                  restart_after(exited, actor, rest, all, maximum_gap_ns)
                Ok(observed) ->
                  Ok(Finding(
                    kind: CrashChain,
                    summary: actor.label
                      <> " restarted with a new PID after "
                      <> int.to_string(gap)
                      <> "ns",
                    evidence: types.inferred(
                      "exit and spawn converge on the same logical actor slot",
                      0.9,
                    ),
                    event_ids: [exited.id, candidate.id, observed.id],
                    value: gap,
                  ))
              }
          }
        }
        _ -> restart_after(exited, actor, rest, all, maximum_gap_ns)
      }
  }
}

fn observed_as_actor(
  events: List(types.TraceEvent),
  child: types.ProcessRef,
  actor: types.LogicalActor,
  spawned_at_ns: Int,
) -> Result(types.TraceEvent, Nil) {
  find_event(events, fn(event) {
    case event.process.logical {
      Some(observed) ->
        event.process.physical == child
        && observed.id == actor.id
        && event.local_timestamp_ns >= spawned_at_ns
      None -> False
    }
  })
}

fn sender_keys(events: List(types.TraceEvent), accumulator: List(String)) {
  case events {
    [] -> list.reverse(accumulator)
    [event, ..rest] ->
      case event.kind {
        types.Send(_, _, _) ->
          sender_keys(
            rest,
            add_unique(accumulator, process_key(event.process.physical)),
          )
        _ -> sender_keys(rest, accumulator)
      }
  }
}

fn receiver_keys(events: List(types.TraceEvent), accumulator: List(String)) {
  case events {
    [] -> list.reverse(accumulator)
    [event, ..rest] ->
      case event.kind {
        types.Received(_, _, _) ->
          receiver_keys(
            rest,
            add_unique(accumulator, process_key(event.process.physical)),
          )
        _ -> receiver_keys(rest, accumulator)
      }
  }
}

fn received_senders(events: List(types.TraceEvent), accumulator: List(String)) {
  case events {
    [] -> list.reverse(accumulator)
    [event, ..rest] ->
      case event.kind {
        types.Received(from, _, _) ->
          received_senders(rest, add_unique(accumulator, process_key(from)))
        _ -> received_senders(rest, accumulator)
      }
  }
}

fn add_unique(items: List(String), item: String) -> List(String) {
  case list.contains(items, item) {
    True -> items
    False -> [item, ..items]
  }
}

fn is_send_by(event: types.TraceEvent, key: String) -> Bool {
  case event.kind {
    types.Send(_, _, _) -> process_key(event.process.physical) == key
    _ -> False
  }
}

fn is_received_by(event: types.TraceEvent, key: String) -> Bool {
  case event.kind {
    types.Received(_, _, _) -> process_key(event.process.physical) == key
    _ -> False
  }
}

fn matching_receive(
  sent: types.TraceEvent,
  events: List(types.TraceEvent),
) -> Result(types.TraceEvent, Nil) {
  case sent.kind {
    types.Send(to, _, serial) ->
      find_event(events, fn(candidate) {
        case candidate.kind {
          types.Received(from, _, received_serial) ->
            candidate.root_id == sent.root_id
            && candidate.node == sent.node
            && received_serial == serial
            && candidate.process.physical == to
            && from == sent.process.physical
          _ -> False
        }
      })
    _ -> Error(Nil)
  }
}

fn call_endpoints(
  event: types.TraceEvent,
) -> Result(#(types.ProcessRef, types.ProcessRef), Nil) {
  case event.kind {
    types.Send(to, types.Tag("call"), _) -> Ok(#(event.process.physical, to))
    _ -> Error(Nil)
  }
}

fn has_reverse_reply(
  events: List(types.TraceEvent),
  caller: types.ProcessRef,
  callee: types.ProcessRef,
  call_at: Int,
) -> Bool {
  list.any(events, fn(event) {
    case event.kind {
      types.Send(to, types.Tag("reply"), _) ->
        event.process.physical == callee
        && to == caller
        && event.local_timestamp_ns >= call_at
      _ -> False
    }
  })
}

fn find_event(
  events: List(types.TraceEvent),
  predicate: fn(types.TraceEvent) -> Bool,
) -> Result(types.TraceEvent, Nil) {
  case events {
    [] -> Error(Nil)
    [event, ..rest] ->
      case predicate(event) {
        True -> Ok(event)
        False -> find_event(rest, predicate)
      }
  }
}

fn process_key(process: types.ProcessRef) -> String {
  process.node <> ":" <> process.pid
}
