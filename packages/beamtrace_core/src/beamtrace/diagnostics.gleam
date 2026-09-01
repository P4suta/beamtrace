//// Bounded offline diagnostics over trace-event lists.
////
//// Findings retain counts, durations, and evidence rather than confidence
//// scores. Empty or unmatched input returns no finding; invalid events should
//// be rejected before this layer. Analyses are linear or O(n log n), depending
//// on grouping, and are portable across Erlang and JavaScript.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/order
import gleam/result
import gleam/string

/// A stable diagnostic category suitable for filtering and reporting.
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

/// A finding's exact count or uncertainty-preserving time estimate.
pub type FindingValue {
  CountValue(Int)
  TimeValue(types.TimeEstimate)
}

/// One bounded diagnostic conclusion with its evidence and source events.
pub type Finding {
  Finding(
    kind: FindingKind,
    summary: String,
    evidence: types.Evidence,
    event_ids: List(String),
    value: FindingValue,
  )
}

type CountAggregate {
  CountAggregate(count: Int, event_ids: List(String))
}

type FanInAggregate {
  FanInAggregate(senders: Dict(String, Bool), event_ids: List(String))
}

type CallIndex {
  CallIndex(
    calls: Dict(String, List(types.TraceEvent)),
    replies: Dict(String, Bool),
  )
}

type RestartCandidate {
  RestartCandidate(
    spawn: types.TraceEvent,
    observed: types.TraceEvent,
    actor: types.LogicalActor,
  )
}

/// Explicit thresholds for every offline analysis. Adjust one field with the
/// record-update syntax on `default_thresholds`.
pub type Thresholds {
  Thresholds(
    hot_sender_messages: Int,
    fan_in_senders: Int,
    queue_wait_ns: Int,
    restart_gap_ns: Int,
    dangling_call_timeout_ns: Int,
  )
}

/// The documented defaults: 100 messages, 100 senders, 100 ms queue waits,
/// 1 s restart gaps, and a 5 s dangling-call timeout.
pub fn default_thresholds() -> Thresholds {
  Thresholds(
    hot_sender_messages: 100,
    fan_in_senders: 100,
    queue_wait_ns: 100_000_000,
    restart_gap_ns: 1_000_000_000,
    dangling_call_timeout_ns: 5_000_000_000,
  )
}

/// Run the four capture-independent analyses — hot senders, fan-in, queue
/// waits, and restart chains — with explicit thresholds. Dangling calls need
/// the capture outcome and a reference time; use `analyze_capture`.
pub fn analyze(
  events: List(types.TraceEvent),
  thresholds thresholds: Thresholds,
) -> List(Finding) {
  list.flatten([
    hot_senders(events, minimum_messages: thresholds.hot_sender_messages),
    fan_in(events, minimum_senders: thresholds.fan_in_senders),
    queue_waits(events, minimum_ns: thresholds.queue_wait_ns),
    restart_chains(events, maximum_gap_ns: thresholds.restart_gap_ns),
  ])
}

/// Run `analyze` plus `dangling_calls`, which only asserts findings when the
/// outcome verifies delivery and needs `now_ns` to age unanswered calls.
pub fn analyze_capture(
  events: List(types.TraceEvent),
  thresholds thresholds: Thresholds,
  outcome outcome: types.CaptureOutcome,
  now_ns now_ns: Int,
) -> List(Finding) {
  list.append(
    analyze(events, thresholds: thresholds),
    dangling_calls(
      events,
      outcome: outcome,
      now_ns: now_ns,
      timeout_ns: thresholds.dangling_call_timeout_ns,
    ),
  )
}

/// Count observed sends with one indexed scan. The diagnostic conclusion is
/// inferred from an exact count and an explicit threshold; it is not a
/// probability statement.
pub fn hot_senders(
  events: List(types.TraceEvent),
  minimum_messages minimum_messages: Int,
) -> List(Finding) {
  events
  |> list.fold(dict.new(), fn(index, event) {
    case event.kind {
      types.Send(_, _, _) -> {
        let key = process_key(event.process.physical)
        let aggregate =
          dict.get(index, key) |> result.unwrap(CountAggregate(0, []))
        dict.insert(
          index,
          key,
          CountAggregate(aggregate.count + 1, [event.id, ..aggregate.event_ids]),
        )
      }
      _ -> index
    }
  })
  |> sorted_entries
  |> list.filter_map(fn(entry) {
    let #(key, aggregate) = entry
    case aggregate.count >= minimum_messages {
      False -> Error(Nil)
      True -> {
        let ids = list.reverse(aggregate.event_ids)
        Ok(Finding(
          kind: HotSender,
          summary: key
            <> " sent "
            <> int.to_string(aggregate.count)
            <> " observed messages",
          evidence: threshold_evidence(
            "observed_hot_sender_count_v2",
            "observed send count reached the configured threshold",
            "messages",
            aggregate.count,
            "minimum_messages",
            minimum_messages,
            ids,
          ),
          event_ids: ids,
          value: CountValue(aggregate.count),
        ))
      }
    }
  })
}

/// Aggregate unique observed senders for each receiver without repeatedly
/// rescanning the event stream.
pub fn fan_in(
  events: List(types.TraceEvent),
  minimum_senders minimum_senders: Int,
) -> List(Finding) {
  events
  |> list.fold(dict.new(), fn(index, event) {
    case event.kind {
      types.Received(from, _, _) -> {
        let key = process_key(event.process.physical)
        let aggregate =
          dict.get(index, key)
          |> result.unwrap(FanInAggregate(dict.new(), []))
        dict.insert(
          index,
          key,
          FanInAggregate(
            dict.insert(aggregate.senders, process_key(from), True),
            [event.id, ..aggregate.event_ids],
          ),
        )
      }
      _ -> index
    }
  })
  |> sorted_entries
  |> list.filter_map(fn(entry) {
    let #(key, aggregate) = entry
    let count = dict.size(aggregate.senders)
    case count >= minimum_senders {
      False -> Error(Nil)
      True -> {
        let ids = list.reverse(aggregate.event_ids)
        Ok(Finding(
          kind: FanIn,
          summary: key
            <> " received from "
            <> int.to_string(count)
            <> " observed senders",
          evidence: threshold_evidence(
            "observed_fan_in_count_v2",
            "observed unique sender count reached the configured threshold",
            "senders",
            count,
            "minimum_senders",
            minimum_senders,
            ids,
          ),
          event_ids: ids,
          value: CountValue(count),
        ))
      }
    }
  })
}

/// Queue wait is exact only for a unique full-serial pair whose send and
/// receive share one node-local monotonic clock. Cross-node and legacy pairs
/// are deliberately omitted because their threshold cannot be decided here.
pub fn queue_waits(
  events: List(types.TraceEvent),
  minimum_ns minimum_ns: Int,
) -> List(Finding) {
  let receives =
    list.fold(events, dict.new(), fn(index, event) {
      case event.kind {
        types.Received(from, _, types.SequenceSerial(_, _) as serial) ->
          put_event(
            index,
            message_key(event.root_id, from, event.process.physical, serial),
            event,
          )
        _ -> index
      }
    })
  events
  |> list.filter_map(fn(sent) {
    case sent.kind {
      types.Send(to, _, types.SequenceSerial(_, _) as serial) ->
        case
          dict.get(
            receives,
            message_key(sent.root_id, sent.process.physical, to, serial),
          )
        {
          Ok([received]) if received.node == sent.node -> {
            let duration =
              received.local_instant.offset_ns - sent.local_instant.offset_ns
            case duration >= minimum_ns && duration >= 0 {
              False -> Error(Nil)
              True ->
                Ok(Finding(
                  kind: QueueWait,
                  summary: "message waited "
                    <> int.to_string(duration)
                    <> "ns before receive",
                  evidence: threshold_evidence(
                    "full_serial_same_node_queue_wait_v2",
                    "a unique full-serial pair shares one node-local clock",
                    "duration_ns",
                    duration,
                    "minimum_ns",
                    minimum_ns,
                    [sent.id, received.id],
                  ),
                  event_ids: [sent.id, received.id],
                  value: TimeValue(types.ExactTime(duration)),
                ))
            }
          }
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

/// Negative evidence is reported only for a delivery-verified capture. Calls
/// with repeated endpoints are left undecided because a reply cannot be
/// paired uniquely without stronger protocol semantics.
pub fn dangling_calls(
  events: List(types.TraceEvent),
  outcome outcome: types.CaptureOutcome,
  now_ns now_ns: Int,
  timeout_ns timeout_ns: Int,
) -> List(Finding) {
  case types.delivery_verified(outcome) {
    False -> []
    True -> {
      let index =
        list.fold(events, CallIndex(dict.new(), dict.new()), fn(index, event) {
          case call_endpoints(event), reply_endpoints(event) {
            Ok(#(caller, callee)), _ ->
              CallIndex(
                put_event(index.calls, call_key(caller, callee), event),
                index.replies,
              )
            _, Ok(#(caller, callee)) ->
              CallIndex(
                index.calls,
                dict.insert(index.replies, call_key(caller, callee), True),
              )
            _, _ -> index
          }
        })
      index.calls
      |> sorted_entries
      |> list.filter_map(fn(entry) {
        let #(key, calls) = entry
        case calls, dict.has_key(index.replies, key) {
          [call], False -> {
            let age = now_ns - call.local_instant.offset_ns
            case age >= timeout_ns && age >= 0 {
              False -> Error(Nil)
              True ->
                Ok(Finding(
                  kind: DanglingCall,
                  summary: "delivery-verified call has no observed reply after "
                    <> int.to_string(age)
                    <> "ns",
                  evidence: types.inferred(
                    "delivery_verified_missing_reply_v2",
                    "no reverse reply was observed before the timeout in a verified capture",
                    [
                      types.EvidenceEvent(call.id),
                      types.ObservedValue("age_ns", int.to_string(age)),
                      types.AlgorithmSetting(
                        "timeout_ns",
                        int.to_string(timeout_ns),
                      ),
                      types.AlgorithmSetting(
                        "endpoint_pairing",
                        "unique_call_endpoints",
                      ),
                    ],
                  ),
                  event_ids: [call.id],
                  value: TimeValue(types.ExactTime(age)),
                ))
            }
          }
          _, _ -> Error(Nil)
        }
      })
    }
  }
}

/// Index process identities, spawns, and exits, then merge each logical actor
/// stream linearly. Positive restart chains use only same-node exact deltas.
pub fn restart_chains(
  events: List(types.TraceEvent),
  maximum_gap_ns maximum_gap_ns: Int,
) -> List(Finding) {
  let observations = actor_observations(events)
  let #(exits, candidates) =
    list.fold(events, #(dict.new(), dict.new()), fn(indexes, event) {
      let #(exits, candidates) = indexes
      case event.kind, event.process.logical {
        types.Exit(_), Some(actor) -> #(
          put_event(exits, restart_key(event.node, actor.id), event),
          candidates,
        )
        types.Spawn(child, _), _ -> {
          case dict.get(observations, process_key(child)) {
            Ok(observed) ->
              case observed.process.logical {
                Some(actor)
                  if observed.node == event.node
                  && observed.local_instant.offset_ns
                  >= event.local_instant.offset_ns
                -> #(
                  exits,
                  put_candidate(
                    candidates,
                    restart_key(event.node, actor.id),
                    RestartCandidate(event, observed, actor),
                  ),
                )
                _ -> indexes
              }
            Error(_) -> indexes
          }
        }
        _, _ -> indexes
      }
    })
  dict.keys(exits)
  |> list.sort(string.compare)
  |> list.fold([], fn(findings, key) {
    let actor_exits =
      dict.get(exits, key)
      |> result.unwrap([])
      |> list.sort(compare_event_time)
    let actor_candidates =
      dict.get(candidates, key)
      |> result.unwrap([])
      |> list.sort(compare_candidate_time)
    list.append(
      findings,
      pair_restarts(actor_exits, actor_candidates, maximum_gap_ns, []),
    )
  })
}

fn pair_restarts(
  exits: List(types.TraceEvent),
  candidates: List(RestartCandidate),
  maximum_gap_ns: Int,
  accumulator: List(Finding),
) -> List(Finding) {
  case exits, candidates {
    [], _ | _, [] -> list.reverse(accumulator)
    [exited, ..rest_exits], [candidate, ..rest_candidates] -> {
      let gap =
        candidate.spawn.local_instant.offset_ns - exited.local_instant.offset_ns
      case gap < 0, gap <= maximum_gap_ns {
        True, _ ->
          pair_restarts(exits, rest_candidates, maximum_gap_ns, accumulator)
        False, True ->
          pair_restarts(rest_exits, rest_candidates, maximum_gap_ns, [
            restart_finding(exited, candidate, gap, maximum_gap_ns),
            ..accumulator
          ])
        False, False ->
          pair_restarts(rest_exits, candidates, maximum_gap_ns, accumulator)
      }
    }
  }
}

fn restart_finding(
  exited: types.TraceEvent,
  candidate: RestartCandidate,
  gap: Int,
  maximum_gap_ns: Int,
) -> Finding {
  Finding(
    kind: CrashChain,
    summary: candidate.actor.label
      <> " restarted with a new PID after "
      <> int.to_string(gap)
      <> "ns",
    evidence: types.inferred(
      "logical_actor_restart_v2",
      "an exit and subsequent spawn converge on the same logical actor slot",
      [
        types.EvidenceEvent(exited.id),
        types.EvidenceEvent(candidate.spawn.id),
        types.EvidenceEvent(candidate.observed.id),
        types.ObservedValue("gap_ns", int.to_string(gap)),
        types.AlgorithmSetting("maximum_gap_ns", int.to_string(maximum_gap_ns)),
      ],
    ),
    event_ids: [exited.id, candidate.spawn.id, candidate.observed.id],
    value: TimeValue(types.ExactTime(gap)),
  )
}

fn actor_observations(
  events: List(types.TraceEvent),
) -> Dict(String, types.TraceEvent) {
  list.fold(events, dict.new(), fn(index, event) {
    case event.process.logical {
      Some(_) -> {
        let key = process_key(event.process.physical)
        case dict.get(index, key) {
          Ok(current) ->
            case compare_event_time(event, current) == order.Lt {
              True -> dict.insert(index, key, event)
              False -> index
            }
          Error(_) -> dict.insert(index, key, event)
        }
      }
      _ -> index
    }
  })
}

fn threshold_evidence(
  method: String,
  reason: String,
  observed_name: String,
  observed: Int,
  setting_name: String,
  setting: Int,
  event_ids: List(String),
) -> types.Evidence {
  types.inferred(
    method,
    reason,
    list.append(
      [
        types.ObservedValue(observed_name, int.to_string(observed)),
        types.AlgorithmSetting(setting_name, int.to_string(setting)),
      ],
      list.map(event_ids, types.EvidenceEvent),
    ),
  )
}

fn put_event(
  index: Dict(String, List(types.TraceEvent)),
  key: String,
  event: types.TraceEvent,
) -> Dict(String, List(types.TraceEvent)) {
  dict.insert(index, key, [event, ..dict.get(index, key) |> result.unwrap([])])
}

fn put_candidate(
  index: Dict(String, List(RestartCandidate)),
  key: String,
  candidate: RestartCandidate,
) -> Dict(String, List(RestartCandidate)) {
  dict.insert(index, key, [
    candidate,
    ..dict.get(index, key)
    |> result.unwrap([])
  ])
}

fn sorted_entries(index: Dict(String, a)) -> List(#(String, a)) {
  index
  |> dict.to_list
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

fn compare_event_time(
  left: types.TraceEvent,
  right: types.TraceEvent,
) -> order.Order {
  case
    int.compare(left.local_instant.offset_ns, right.local_instant.offset_ns)
  {
    order.Eq -> int.compare(left.local_instant.order, right.local_instant.order)
    other -> other
  }
}

fn compare_candidate_time(
  left: RestartCandidate,
  right: RestartCandidate,
) -> order.Order {
  compare_event_time(left.spawn, right.spawn)
}

fn call_endpoints(
  event: types.TraceEvent,
) -> Result(#(types.ProcessRef, types.ProcessRef), Nil) {
  case event.kind {
    types.Send(to, types.TagOnly("call"), _) ->
      Ok(#(event.process.physical, to))
    _ -> Error(Nil)
  }
}

fn reply_endpoints(
  event: types.TraceEvent,
) -> Result(#(types.ProcessRef, types.ProcessRef), Nil) {
  case event.kind {
    types.Send(to, types.TagOnly("reply"), _) ->
      Ok(#(to, event.process.physical))
    _ -> Error(Nil)
  }
}

fn call_key(caller: types.ProcessRef, callee: types.ProcessRef) -> String {
  process_key(caller) <> "\u{1f}" <> process_key(callee)
}

fn message_key(
  root_id: String,
  from: types.ProcessRef,
  to: types.ProcessRef,
  serial: types.SequenceSerial,
) -> String {
  let assert types.SequenceSerial(previous, current) = serial
  root_id
  <> "\u{1f}"
  <> process_key(from)
  <> "\u{1f}"
  <> process_key(to)
  <> "\u{1f}"
  <> int.to_string(previous)
  <> ":"
  <> int.to_string(current)
}

fn restart_key(node: String, actor_id: String) -> String {
  node <> "\u{1f}" <> actor_id
}

fn process_key(process: types.ProcessRef) -> String {
  process.node <> "\u{0}" <> process.pid
}
