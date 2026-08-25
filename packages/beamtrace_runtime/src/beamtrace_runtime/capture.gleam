import beamtrace/aql
import beamtrace/dag
import beamtrace/identity
import beamtrace/types
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type RawProcessMetadata {
  RawProcessMetadata(
    registered_name: String,
    process_label: String,
    initial_module: String,
    initial_function: String,
    initial_arity: Int,
    ancestors: List(String),
    supervisor_child_id: String,
  )
}

/// A bounded, privacy-shaped term emitted by the dependency-free target
/// agent. Empty display/fingerprint strings represent absent optional data.
pub type RawTermView {
  RawHidden
  RawAtom(name: String)
  RawTuple(size: Int, items: List(RawTermView))
  RawList(length: Int, items: List(RawTermView))
  RawMap(size: Int, entries: List(#(RawTermView, RawTermView)))
  RawBinary(bytes: Int, display: String, fingerprint: String)
  RawScalar(kind: String, display: String, fingerprint: String)
  RawRedacted(reason: String)
}

pub type RawEvent {
  RawEventV2(
    id: String,
    root_id: String,
    node: String,
    process_pid: String,
    local_offset_ns: Int,
    local_order: Int,
    kind: String,
    peer_node: String,
    peer_pid: String,
    previous_serial: Int,
    current_serial: Int,
    semantic: String,
    metadata: RawProcessMetadata,
    term: RawTermView,
  )
  RawEvent(
    id: String,
    root_id: String,
    node: String,
    process_pid: String,
    local_timestamp_ns: Int,
    kind: String,
    peer_node: String,
    peer_pid: String,
    serial: Int,
    semantic: String,
  )
  RawEventWithMetadata(
    id: String,
    root_id: String,
    node: String,
    process_pid: String,
    local_timestamp_ns: Int,
    kind: String,
    peer_node: String,
    peer_pid: String,
    serial: Int,
    semantic: String,
    metadata: RawProcessMetadata,
  )
  RawEventWithTerm(
    id: String,
    root_id: String,
    node: String,
    process_pid: String,
    local_timestamp_ns: Int,
    kind: String,
    peer_node: String,
    peer_pid: String,
    serial: Int,
    semantic: String,
    metadata: RawProcessMetadata,
    term: RawTermView,
  )
}

pub type RawCaptureIssue {
  RawCaptureIssue(
    kind: String,
    node: String,
    field: String,
    expected: Int,
    actual: Int,
  )
}

pub type RawNodeReceipt {
  RawNodeReceipt(
    node: String,
    final_batch_sequence: Int,
    event_count: Int,
    byte_count: Int,
  )
}

pub type RawOutcome {
  RawOutcome(
    end_kind: String,
    end_detail: String,
    issues: List(RawCaptureIssue),
    receipts: List(RawNodeReceipt),
  )
}

pub type CaptureResult {
  CaptureResult(
    events: List(types.TraceEvent),
    outcome: types.CaptureOutcome,
    clocks: types.ClockCalibration,
  )
}

pub type Budget {
  Budget(max_events: Int, max_bytes: Int, max_agent_mailbox: Int)
}

pub type MfaCandidate {
  MfaCandidate(node: String, module_: String, function_: String, arity: Int)
}

pub type PreparedCapture {
  PreparedCapture(
    spec: types.CaptureSpec,
    predicate: aql.AgentPredicate,
    residual: Option(aql.Query),
  )
}

pub fn default_budget() -> Budget {
  Budget(100_000, 64_000_000, 10_000)
}

pub fn prepare(spec: types.CaptureSpec) -> Result(PreparedCapture, String) {
  use Nil <- try_result(validate_spec(spec))
  case spec.where_aql {
    None -> Ok(PreparedCapture(spec, aql.AgentAlways, None))
    Some(source) ->
      case aql.parse(source) {
        Error(error) ->
          Error(
            "invalid_aql_at_"
            <> int.to_string(error.offset)
            <> ":"
            <> error.message,
          )
        Ok(query) -> {
          let plan = aql.compile_trigger(query, spec.trigger)
          case plan.predicate {
            aql.AgentNever -> Error("capture_filter_cannot_match_trigger")
            predicate -> Ok(PreparedCapture(spec, predicate, plan.residual))
          }
        }
      }
  }
}

pub fn execute(
  spec: types.CaptureSpec,
  cookie: String,
) -> Result(CaptureResult, String) {
  use prepared <- try_result(prepare(spec))
  let budget = spec.budget
  let types.Mfa(module_, function_, arity) = spec.trigger
  use payload <- try_result(case spec.nodes {
    [node] ->
      collect_remote_spec(
        node,
        cookie,
        module_,
        function_,
        arity,
        budget.max_duration_ms,
        budget.drain_timeout_ms,
        budget.max_events,
        budget.max_bytes,
        budget.max_agent_mailbox,
        budget.max_roots,
        prepared.predicate,
        spec.privacy,
        spec.preset,
      )
    [_, _, ..] ->
      collect_distributed_spec(
        spec.nodes,
        cookie,
        module_,
        function_,
        arity,
        budget.max_duration_ms,
        budget.drain_timeout_ms,
        budget.max_events,
        budget.max_bytes,
        budget.max_agent_mailbox,
        budget.max_roots,
        prepared.predicate,
        spec.privacy,
        spec.preset,
      )
    [] -> Error("capture_requires_at_least_one_node")
  })
  let #(events, raw_outcome, clocks) = payload
  let result = normalize_v2(events, raw_outcome, clocks, spec.trigger)
  case prepared.residual {
    None -> Ok(result)
    Some(query) -> Ok(filter_roots(result, query, spec.trigger))
  }
}

fn validate_spec(spec: types.CaptureSpec) -> Result(Nil, String) {
  let budget = spec.budget
  case
    spec.nodes,
    list.length(spec.nodes) <= 32,
    unique_nodes(spec.nodes),
    budget.max_events > 0,
    budget.max_bytes > 0,
    budget.max_duration_ms > 0 && budget.max_duration_ms <= 300_000,
    budget.drain_timeout_ms >= 1000 && budget.drain_timeout_ms <= 60_000,
    budget.max_agent_mailbox > 0,
    budget.max_roots > 0 && budget.max_roots <= 1000,
    valid_privacy(spec.privacy)
  {
    [], _, _, _, _, _, _, _, _, _ -> Error("capture_requires_at_least_one_node")
    _, False, _, _, _, _, _, _, _, _ -> Error("too_many_capture_nodes")
    _, _, False, _, _, _, _, _, _, _ -> Error("duplicate_capture_node")
    _, _, _, False, _, _, _, _, _, _ -> Error("invalid_event_budget")
    _, _, _, _, False, _, _, _, _, _ -> Error("invalid_byte_budget")
    _, _, _, _, _, False, _, _, _, _ -> Error("invalid_capture_window")
    _, _, _, _, _, _, False, _, _, _ -> Error("invalid_drain_timeout")
    _, _, _, _, _, _, _, False, _, _ -> Error("invalid_mailbox_budget")
    _, _, _, _, _, _, _, _, False, _ -> Error("invalid_root_budget")
    _, _, _, _, _, _, _, _, _, False -> Error("invalid_privacy_policy")
    _, True, True, True, True, True, True, True, True, True -> Ok(Nil)
  }
}

fn unique_nodes(nodes: List(String)) -> Bool {
  list.length(nodes) == list.length(unique_strings(nodes, []))
}

fn unique_strings(values: List(String), seen: List(String)) -> List(String) {
  case values {
    [] -> seen
    [value, ..rest] ->
      case value != "" && !list.contains(seen, value) {
        True -> unique_strings(rest, [value, ..seen])
        False -> seen
      }
  }
}

fn valid_privacy(privacy: types.Privacy) -> Bool {
  case privacy {
    types.Metadata -> True
    types.Raw(policy) ->
      policy.max_depth > 0
      && policy.max_depth <= 32
      && policy.max_binary_bytes > 0
      && policy.max_binary_bytes <= 1_048_576
      && policy.redact_keys != []
      && list.length(policy.redact_keys) <= 128
  }
}

pub fn normalize(
  events: List(RawEvent),
  completeness: String,
  trigger: types.Mfa,
) -> CaptureResult {
  normalize_v2(
    events,
    legacy_raw_outcome(completeness),
    types.empty_calibration(),
    trigger,
  )
}

pub fn normalize_v2(
  events: List(RawEvent),
  outcome: RawOutcome,
  clocks: types.ClockCalibration,
  trigger: types.Mfa,
) -> CaptureResult {
  let normalized =
    list.map(events, fn(event) { normalize_event(event, trigger) })
  CaptureResult(
    events: normalized |> disambiguate_roots |> propagate_process_identities,
    outcome: normalize_outcome(outcome),
    clocks: clocks,
  )
}

fn disambiguate_roots(
  events: List(types.TraceEvent),
) -> List(types.TraceEvent) {
  let groups = root_groups(events)
  let seeded =
    list.map(events, fn(event) {
      case event.kind, dict.get(groups, event.root_id) {
        types.Root(_, _), Ok([_, _, ..]) ->
          types.TraceEvent(..event, root_id: event.id)
        _, _ -> event
      }
    })
  case dag.build(seeded) {
    Error(_) ->
      mark_unattributed_roots(seeded, groups, "causal graph is cyclic")
    Ok(graph) -> {
      let reachable = exact_root_reachability(graph)
      list.map(seeded, fn(event) {
        case event.kind, dict.get(groups, event.root_id) {
          types.Root(_, _), _ -> event
          _, Ok(group) ->
            case group {
              [_, _, ..] -> {
                let reached = dict_get_list(reachable, event.id)
                let candidates =
                  list.filter(group, fn(root) { list.contains(reached, root) })
                attribute_reachable_root(event, candidates)
              }
              _ -> event
            }
          _, Error(_) -> event
        }
      })
    }
  }
}

fn root_groups(events: List(types.TraceEvent)) -> Dict(String, List(String)) {
  list.fold(events, dict.new(), fn(groups, event) {
    case event.kind {
      types.Root(_, _) ->
        dict.insert(groups, event.root_id, [
          event.id,
          ..dict_get_list(groups, event.root_id)
        ])
      _ -> groups
    }
  })
}

fn attribute_reachable_root(
  event: types.TraceEvent,
  candidates: List(String),
) -> types.TraceEvent {
  case candidates {
    [root_id] -> types.TraceEvent(..event, root_id: root_id)
    [] ->
      types.TraceEvent(
        ..event,
        root_id: "unattributed:" <> event.root_id,
        evidence: root_attribution_evidence(
          event.id,
          [],
          "no exact causal path from any candidate root",
        ),
      )
    [_, _, ..] ->
      types.TraceEvent(
        ..event,
        root_id: "ambiguous:" <> event.root_id,
        evidence: root_attribution_evidence(
          event.id,
          candidates,
          "event is exactly reachable from multiple roots",
        ),
      )
  }
}

fn root_attribution_evidence(
  event_id: String,
  candidates: List(String),
  reason: String,
) -> types.Evidence {
  types.inferred("exact_graph_root_reachability", reason, [
    types.EvidenceEvent(event_id),
    types.ObservedValue("candidate_roots", string.join(candidates, ",")),
    types.AlgorithmSetting("edge_policy", "Exact only"),
  ])
}

fn mark_unattributed_roots(
  events: List(types.TraceEvent),
  groups: Dict(String, List(String)),
  reason: String,
) -> List(types.TraceEvent) {
  list.map(events, fn(event) {
    case event.kind, dict.get(groups, event.root_id) {
      types.Root(_, _), _ -> event
      _, Ok([_, _, ..]) ->
        types.TraceEvent(
          ..event,
          root_id: "unattributed:" <> event.root_id,
          evidence: root_attribution_evidence(event.id, [], reason),
        )
      _, _ -> event
    }
  })
}

fn exact_root_reachability(
  graph: dag.CausalGraph,
) -> Dict(String, List(String)) {
  let indegree =
    list.fold(graph.events, dict.new(), fn(index, event) {
      dict.insert(index, event.id, 0)
    })
  let memberships =
    list.fold(graph.events, dict.new(), fn(index, event) {
      case event.kind {
        types.Root(_, _) -> dict.insert(index, event.id, [event.id])
        _ -> index
      }
    })
  let #(adjacency, indegree) =
    list.fold(graph.edges, #(dict.new(), indegree), fn(indexes, edge) {
      let #(adjacency, indegree) = indexes
      case edge.evidence {
        types.Exact -> {
          let outgoing = dict_get_list(adjacency, edge.from)
          let degree = dict_get_int(indegree, edge.to)
          #(
            dict.insert(adjacency, edge.from, [edge.to, ..outgoing]),
            dict.insert(indegree, edge.to, degree + 1),
          )
        }
        types.Inferred(_) -> indexes
      }
    })
  let ready =
    indegree
    |> dict.to_list
    |> list.filter_map(fn(entry) {
      case entry.1 == 0 {
        True -> Ok(entry.0)
        False -> Error(Nil)
      }
    })
  propagate_root_sets(ready, adjacency, indegree, memberships)
}

fn propagate_root_sets(
  ready: List(String),
  adjacency: Dict(String, List(String)),
  indegree: Dict(String, Int),
  memberships: Dict(String, List(String)),
) -> Dict(String, List(String)) {
  case ready {
    [] -> memberships
    [id, ..rest] -> {
      let roots = dict_get_list(memberships, id)
      let #(next_indegree, next_memberships, newly_ready) =
        list.fold(
          dict_get_list(adjacency, id),
          #(indegree, memberships, []),
          fn(state, target) {
            let #(degrees, roots_by_event, zeroes) = state
            let degree = dict_get_int(degrees, target) - 1
            let propagated =
              unique_append(dict_get_list(roots_by_event, target), roots)
            #(
              dict.insert(degrees, target, degree),
              dict.insert(roots_by_event, target, propagated),
              case degree == 0 {
                True -> [target, ..zeroes]
                False -> zeroes
              },
            )
          },
        )
      propagate_root_sets(
        list.append(rest, list.reverse(newly_ready)),
        adjacency,
        next_indegree,
        next_memberships,
      )
    }
  }
}

fn unique_append(left: List(String), right: List(String)) -> List(String) {
  list.fold(right, left, fn(values, value) {
    case list.contains(values, value) {
      True -> values
      False -> [value, ..values]
    }
  })
}

fn dict_get_list(
  values: Dict(String, List(String)),
  key: String,
) -> List(String) {
  case dict.get(values, key) {
    Ok(value) -> value
    Error(_) -> []
  }
}

fn dict_get_int(values: Dict(String, Int), key: String) -> Int {
  case dict.get(values, key) {
    Ok(value) -> value
    Error(_) -> 0
  }
}

fn propagate_process_identities(
  events: List(types.TraceEvent),
) -> List(types.TraceEvent) {
  let known =
    list.fold(events, dict.new(), fn(known, event) {
      case
        event.process.logical,
        dict.get(known, process_key(event.process.physical))
      {
        Some(_), Error(_) ->
          dict.insert(known, process_key(event.process.physical), event.process)
        _, _ -> known
      }
    })

  list.map(events, fn(event) {
    case dict.get(known, process_key(event.process.physical)) {
      Ok(process) -> types.TraceEvent(..event, process: process)
      Error(_) -> event
    }
  })
}

fn process_key(process: types.ProcessRef) -> String {
  process.node <> "\u{0}" <> process.pid
}

fn normalize_event(event: RawEvent, trigger: types.Mfa) -> types.TraceEvent {
  let physical = types.ProcessRef(event.node, event.process_pid)
  let process = case event {
    RawEventV2(_, _, _, _, _, _, _, _, _, _, _, _, metadata, _) ->
      identity.resolve(physical, process_metadata(metadata))
    RawEvent(_, _, _, _, _, _, _, _, _, _) ->
      types.ProcessIdentity(physical: physical, logical: None, evidence: [])
    RawEventWithMetadata(_, _, _, _, _, _, _, _, _, _, metadata)
    | RawEventWithTerm(_, _, _, _, _, _, _, _, _, _, metadata, _) ->
      identity.resolve(physical, process_metadata(metadata))
  }
  let #(peer_node, peer_pid) = raw_event_peer(event)
  let peer = types.ProcessRef(peer_node, peer_pid)
  let semantic = raw_event_semantic(event)
  let message = shaped_term(event, types.Tag(semantic))
  let kind = case raw_event_kind(event) {
    "root" -> types.Root(trigger, root_arguments(event))
    "send" -> types.Send(peer, message, event_serial(event))
    "receive" -> types.Received(peer, message, event_serial(event))
    "print" ->
      types.SystemSignal("seq_trace_print", serial_current(event_serial(event)))
    "spawn" ->
      case parse_mfa(semantic) {
        Ok(initial_call) -> types.Spawn(peer, initial_call)
        Error(_) -> types.Gap(1, "invalid spawn initial call")
      }
    "exit" -> types.Exit(message)
    "register" -> types.Register(semantic)
    "link" -> types.Link(peer)
    "gap" -> types.Gap(1, "relay backpressure")
    unknown -> types.Gap(1, "unknown relay event: " <> unknown)
  }

  types.TraceEvent(
    id: event.id,
    root_id: event.root_id,
    node: event.node,
    process: process,
    local_instant: event_instant(event),
    kind: kind,
    evidence: types.Exact,
  )
}

fn raw_event_peer(event: RawEvent) -> #(String, String) {
  case event {
    RawEventV2(_, _, _, _, _, _, _, node, pid, _, _, _, _, _)
    | RawEvent(_, _, _, _, _, _, node, pid, _, _)
    | RawEventWithMetadata(_, _, _, _, _, _, node, pid, _, _, _)
    | RawEventWithTerm(_, _, _, _, _, _, node, pid, _, _, _, _) -> #(node, pid)
  }
}

fn raw_event_kind(event: RawEvent) -> String {
  case event {
    RawEventV2(_, _, _, _, _, _, kind, _, _, _, _, _, _, _)
    | RawEvent(_, _, _, _, _, kind, _, _, _, _)
    | RawEventWithMetadata(_, _, _, _, _, kind, _, _, _, _, _)
    | RawEventWithTerm(_, _, _, _, _, kind, _, _, _, _, _, _) -> kind
  }
}

fn raw_event_semantic(event: RawEvent) -> String {
  case event {
    RawEventV2(_, _, _, _, _, _, _, _, _, _, _, semantic, _, _)
    | RawEvent(_, _, _, _, _, _, _, _, _, semantic)
    | RawEventWithMetadata(_, _, _, _, _, _, _, _, _, semantic, _)
    | RawEventWithTerm(_, _, _, _, _, _, _, _, _, semantic, _, _) -> semantic
  }
}

fn event_instant(event: RawEvent) -> types.LocalInstant {
  case event {
    RawEventV2(_, _, _, _, offset, order, _, _, _, _, _, _, _, _) ->
      types.LocalInstant(offset, order)
    RawEvent(_, _, _, _, timestamp, _, _, _, _, _)
    | RawEventWithMetadata(_, _, _, _, timestamp, _, _, _, _, _, _)
    | RawEventWithTerm(_, _, _, _, timestamp, _, _, _, _, _, _, _) ->
      types.LocalInstant(timestamp, 0)
  }
}

fn event_serial(event: RawEvent) -> types.SequenceSerial {
  case event {
    RawEventV2(_, _, _, _, _, _, _, _, _, previous, current, _, _, _) ->
      types.SequenceSerial(previous, current)
    RawEvent(_, _, _, _, _, _, _, _, serial, _)
    | RawEventWithMetadata(_, _, _, _, _, _, _, _, serial, _, _)
    | RawEventWithTerm(_, _, _, _, _, _, _, _, serial, _, _, _) ->
      types.LegacySerial(serial)
  }
}

fn serial_current(serial: types.SequenceSerial) -> Int {
  case serial {
    types.SequenceSerial(_, current) | types.LegacySerial(current) -> current
  }
}

fn shaped_term(event: RawEvent, fallback: types.TermView) -> types.TermView {
  case event {
    RawEventV2(_, _, _, _, _, _, _, _, _, _, _, _, _, term) ->
      normalize_term(term)
    RawEventWithTerm(_, _, _, _, _, _, _, _, _, _, _, term) ->
      normalize_term(term)
    _ -> fallback
  }
}

fn root_arguments(event: RawEvent) -> List(types.TermView) {
  case event {
    RawEventV2(_, _, _, _, _, _, _, _, _, _, _, _, _, RawList(_, items)) ->
      list.map(items, normalize_term)
    RawEventWithTerm(_, _, _, _, _, _, _, _, _, _, _, RawList(_, items)) ->
      list.map(items, normalize_term)
    _ -> []
  }
}

fn normalize_term(term: RawTermView) -> types.TermView {
  case term {
    RawHidden -> types.Hidden
    RawAtom(name) -> types.Atom(name)
    RawTuple(_, [RawAtom(name), ..fields]) ->
      types.Constructor(name, list.map(fields, normalize_term))
    RawTuple(_, items) -> types.Tuple(list.map(items, normalize_term))
    RawList(length, items) ->
      types.ListView(length, list.map(items, normalize_term))
    RawMap(size, entries) ->
      types.MapView(
        size,
        list.map(entries, fn(entry) {
          #(normalize_term(entry.0), normalize_term(entry.1))
        }),
      )
    RawBinary(bytes, display, fingerprint) ->
      types.BinaryMetadata(bytes, non_empty(display), non_empty(fingerprint))
    RawScalar(kind, display, fingerprint) ->
      types.Scalar(kind, non_empty(display), non_empty(fingerprint))
    RawRedacted(reason) -> types.Redacted(reason)
  }
}

fn process_metadata(metadata: RawProcessMetadata) -> types.ProcessMetadata {
  types.ProcessMetadata(
    registered_name: non_empty(metadata.registered_name),
    process_label: non_empty(metadata.process_label),
    initial_call: optional_mfa(
      metadata.initial_module,
      metadata.initial_function,
      metadata.initial_arity,
    ),
    ancestors: list.filter(metadata.ancestors, fn(value) { value != "" }),
    supervisor_child_id: non_empty(metadata.supervisor_child_id),
  )
}

fn non_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    value -> Some(value)
  }
}

fn optional_mfa(module_: String, function_: String, arity: Int) {
  case module_ != "" && function_ != "" && arity >= 0 {
    True -> Some(types.Mfa(module_, function_, arity))
    False -> None
  }
}

fn parse_mfa(source: String) -> Result(types.Mfa, Nil) {
  case string.split_once(source, ":") {
    Ok(#(module_, function_and_arity)) if module_ != "" ->
      case string.split_once(function_and_arity, "/") {
        Ok(#(function_, arity_source)) if function_ != "" ->
          case int.parse(arity_source) {
            Ok(arity) if arity >= 0 -> Ok(types.Mfa(module_, function_, arity))
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn legacy_raw_outcome(source: String) -> RawOutcome {
  case source {
    "complete" ->
      RawOutcome(
        "legacy_unknown",
        "",
        [
          RawCaptureIssue(
            "legacy_unverified",
            "",
            "v1 completeness was not delivery verified",
            0,
            0,
          ),
        ],
        [],
      )
    _ ->
      case string.split_once(source, ":") {
        Ok(#("truncated", reason)) ->
          RawOutcome("budget_reached", reason, [], [])
        Ok(#("gapped", count)) ->
          RawOutcome(
            "legacy_unknown",
            "",
            [
              RawCaptureIssue(
                "legacy_unverified",
                "",
                "v1 reported a gap of "
                  <> count
                  <> " events without a verifiable node receipt",
                0,
                0,
              ),
            ],
            [],
          )
        Ok(#("partial_node", nodes)) ->
          RawOutcome(
            "legacy_unknown",
            "",
            [
              RawCaptureIssue(
                "legacy_unverified",
                "",
                "v1 reported partial nodes without receipts: " <> nodes,
                0,
                0,
              ),
            ],
            [],
          )
        Ok(#("inferred", reason)) ->
          RawOutcome(
            "legacy_unknown",
            "",
            [RawCaptureIssue("legacy_unverified", "", reason, 0, 0)],
            [],
          )
        _ ->
          RawOutcome(
            "legacy_unknown",
            "",
            [RawCaptureIssue("legacy_unverified", "", source, 0, 0)],
            [],
          )
      }
  }
}

fn normalize_outcome(raw: RawOutcome) -> types.CaptureOutcome {
  types.CaptureOutcome(
    normalize_end(raw.end_kind, raw.end_detail, raw.issues),
    list.map(raw.issues, normalize_issue),
    list.map(raw.receipts, fn(receipt) {
      types.NodeReceipt(
        receipt.node,
        receipt.final_batch_sequence,
        receipt.event_count,
        receipt.byte_count,
      )
    }),
  )
}

fn normalize_end(
  kind: String,
  detail: String,
  issues: List(RawCaptureIssue),
) -> types.ObservationEnd {
  case kind {
    "quiet_period" -> types.QuietPeriod(parse_non_negative(detail, 250))
    "time_window" -> types.TimeWindow(parse_non_negative(detail, 0))
    "user_stopped" -> types.UserStopped
    "budget_reached" -> types.BudgetReached(detail)
    "agent_failure" ->
      case issues {
        [issue, ..] -> types.AgentFailure(issue.node, detail)
        [] -> types.AgentFailure("unknown@node", detail)
      }
    _ -> types.LegacyUnknown
  }
}

fn normalize_issue(raw: RawCaptureIssue) -> types.CaptureIssue {
  case raw.kind {
    "dropped_events" -> types.DroppedEvents(raw.node, raw.expected)
    "missing_node" -> types.MissingNode(raw.node)
    "batch_sequence_gap" ->
      types.BatchSequenceGap(raw.node, raw.expected, raw.actual)
    "duplicate_batch" -> types.DuplicateBatch(raw.node, raw.actual)
    "receipt_mismatch" ->
      types.ReceiptMismatch(raw.node, raw.field, raw.expected, raw.actual)
    "drain_timeout" -> types.DrainTimeout(raw.node, raw.actual)
    _ -> types.LegacyUnverified(raw.field)
  }
}

fn parse_non_negative(source: String, fallback: Int) -> Int {
  case int.parse(source) {
    Ok(value) if value >= 0 -> value
    _ -> fallback
  }
}

pub fn exit_code(outcome: types.CaptureOutcome) -> Int {
  case outcome.issues, outcome.end {
    [], types.QuietPeriod(_)
    | [], types.TimeWindow(_)
    | [], types.UserStopped
    -> 0
    _, _ -> 3
  }
}

pub fn failure_exit_code(reason: String) -> Int {
  case reason {
    "system_tracer_occupied" -> 4
    _ -> 2
  }
}

pub fn failure_guidance(reason: String) -> String {
  case reason {
    "system_tracer_occupied" ->
      "Exact capture was refused because another system tracer owns the node. "
      <> "BeamTrace did not replace it; use Live for bounded inferred sampling."
    _ -> reason
  }
}

pub fn filter_roots(
  result: CaptureResult,
  query: aql.Query,
  trigger: types.Mfa,
) -> CaptureResult {
  let matching_roots =
    list.fold(result.events, [], fn(roots, event) {
      case aql.evaluate(query, event_context(event, trigger)) {
        True ->
          case list.contains(roots, event.root_id) {
            True -> roots
            False -> [event.root_id, ..roots]
          }
        False -> roots
      }
    })
  CaptureResult(
    ..result,
    events: list.filter(result.events, fn(event) {
      list.contains(matching_roots, event.root_id)
    }),
  )
}

fn event_context(event: types.TraceEvent, trigger: types.Mfa) {
  let common = [
    #("node", aql.StringValue(event.node)),
    #("process.pid", aql.StringValue(event.process.physical.pid)),
    #("root_id", aql.StringValue(event.root_id)),
    #("event.kind", aql.StringValue(event_kind_name(event.kind))),
    #("exact", aql.BoolValue(event.evidence == types.Exact)),
    #("timestamp_ns", aql.IntValue(event.local_instant.offset_ns)),
  ]
  let process = process_context(event.process)
  let specific = case event.kind {
    types.Root(_, arguments) ->
      list.append(
        [
          #("mfa", aql.StringValue(mfa_name(trigger))),
          #("module", aql.StringValue(trigger.module_)),
          #("function", aql.StringValue(trigger.function_)),
          #("arity", aql.IntValue(trigger.arity)),
          #("arg.count", aql.IntValue(list.length(arguments))),
        ],
        argument_context(arguments, 0, []),
      )
    types.Send(_, message, _) | types.Received(_, message, _) ->
      term_context("message", message)
    _ -> []
  }
  dict.from_list(common |> list.append(process) |> list.append(specific))
}

fn process_context(
  process: types.ProcessIdentity,
) -> List(#(String, aql.Value)) {
  let logical = case process.logical {
    Some(actor) -> [
      #("process.label", aql.StringValue(actor.label)),
      #("process.logical_id", aql.StringValue(actor.id)),
    ]
    None -> []
  }
  list.fold(process.evidence, logical, fn(fields, evidence) {
    case evidence {
      types.RegisteredName(value) -> [
        #("process.registered_name", aql.StringValue(value)),
        ..fields
      ]
      types.ProcessLabel(value) -> [
        #("process.label", aql.StringValue(value)),
        ..fields
      ]
      types.InitialCall(value) -> [
        #("process.initial_call", aql.StringValue(mfa_name(value))),
        ..fields
      ]
      types.Ancestor(value) -> [
        #("process.ancestor", aql.StringValue(value)),
        ..fields
      ]
      types.SupervisorChildId(value) -> [
        #("process.child_id", aql.StringValue(value)),
        ..fields
      ]
      types.RestartProximity(value) -> [
        #("process.restart_proximity_ms", aql.IntValue(value)),
        ..fields
      ]
    }
  })
}

fn argument_context(
  arguments: List(types.TermView),
  index: Int,
  fields: List(#(String, aql.Value)),
) -> List(#(String, aql.Value)) {
  case arguments {
    [] -> list.reverse(fields)
    [argument, ..rest] ->
      argument_context(
        rest,
        index + 1,
        list.reverse(term_context("arg." <> int.to_string(index), argument))
          |> list.append(fields),
      )
  }
}

fn term_context(prefix: String, term: types.TermView) {
  let tag = case message_tag(term) {
    "" -> []
    value -> [#(prefix <> ".tag", aql.StringValue(value))]
  }
  let size = case term_size(term) {
    None -> []
    Some(value) -> [#(prefix <> ".size", aql.IntValue(value))]
  }
  [#(prefix <> ".type", aql.StringValue(term_type(term))), ..tag]
  |> list.append(size)
}

fn term_type(term: types.TermView) -> String {
  case term {
    types.Hidden -> "hidden"
    types.Atom(_) | types.Tag(_) -> "atom"
    types.Tuple(_) | types.Constructor(_, _) -> "tuple"
    types.ListView(_, _) -> "list"
    types.MapView(_, _) -> "map"
    types.BinaryMetadata(_, _, _) -> "binary"
    types.Scalar(kind, _, _) -> kind
    types.Redacted(_) -> "redacted"
  }
}

fn term_size(term: types.TermView) -> Option(Int) {
  case term {
    types.Tuple(items) -> Some(list.length(items))
    types.Constructor(_, fields) -> Some(list.length(fields) + 1)
    types.ListView(length, _) -> Some(length)
    types.MapView(size, _) -> Some(size)
    types.BinaryMetadata(bytes, _, _) -> Some(bytes)
    _ -> None
  }
}

fn event_kind_name(kind: types.TraceEventKind) -> String {
  case kind {
    types.Root(_, _) -> "root"
    types.Send(_, _, _) -> "send"
    types.Received(_, _, _) -> "receive"
    types.Spawn(_, _) -> "spawn"
    types.Exit(_) -> "exit"
    types.Register(_) -> "register"
    types.Link(_) -> "link"
    types.Metric(_, _) -> "metric"
    types.SystemSignal(_, _) -> "system_signal"
    types.Gap(_, _) -> "gap"
    types.Stop(_) -> "stop"
  }
}

fn message_tag(message: types.TermView) -> String {
  case message {
    types.Tag(value) | types.Atom(value) | types.Constructor(value, _) -> value
    _ -> ""
  }
}

fn mfa_name(mfa: types.Mfa) -> String {
  mfa.module_ <> ":" <> mfa.function_ <> "/" <> int.to_string(mfa.arity)
}

pub fn remote(
  node: String,
  cookie: String,
  trigger: types.Mfa,
  capture_window_ms: Int,
  budget: Budget,
) -> Result(CaptureResult, String) {
  execute(
    types.CaptureSpec(
      nodes: [node],
      trigger: trigger,
      where_aql: None,
      privacy: types.Metadata,
      budget: types.TraceBudget(
        max_events: budget.max_events,
        max_bytes: budget.max_bytes,
        max_duration_ms: capture_window_ms,
        drain_timeout_ms: 10_000,
        max_agent_mailbox: budget.max_agent_mailbox,
        max_roots: 1,
      ),
      preset: types.Generic,
    ),
    cookie,
  )
}

pub fn distributed(
  nodes: List(String),
  cookie: String,
  trigger: types.Mfa,
  capture_window_ms: Int,
  budget: Budget,
) -> Result(CaptureResult, String) {
  case nodes {
    [] -> Error("capture_requires_at_least_one_node")
    [_, ..] -> {
      execute(
        types.CaptureSpec(
          nodes: nodes,
          trigger: trigger,
          where_aql: None,
          privacy: types.Metadata,
          budget: types.TraceBudget(
            max_events: budget.max_events,
            max_bytes: budget.max_bytes,
            max_duration_ms: capture_window_ms,
            drain_timeout_ms: 10_000,
            max_agent_mailbox: budget.max_agent_mailbox,
            max_roots: 1,
          ),
          preset: types.Generic,
        ),
        cookie,
      )
    }
  }
}

pub fn probe(node: String, cookie: String) -> Result(String, String) {
  probe_remote(node, cookie)
}

pub fn search_mfas(
  node: String,
  cookie: String,
  query: String,
  limit: Int,
) -> Result(List(MfaCandidate), String) {
  case string.length(query) <= 256 && limit > 0 && limit <= 200 {
    True -> search_remote(node, cookie, query, limit)
    False -> Error("invalid_mfa_search")
  }
}

pub fn wait_until_armed(
  node: String,
  cookie: String,
  timeout_ms: Int,
) -> Result(Nil, String) {
  wait_remote_armed(node, cookie, timeout_ms)
}

pub fn wait_until_available(
  node: String,
  cookie: String,
  timeout_ms: Int,
) -> Result(Nil, String) {
  wait_remote_available(node, cookie, timeout_ms)
}

fn try_result(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

@external(erlang, "beamtrace_capture_ffi", "collect_remote_spec")
fn collect_remote_spec(
  node: String,
  cookie: String,
  module_: String,
  function_: String,
  arity: Int,
  capture_window_ms: Int,
  drain_timeout_ms: Int,
  max_events: Int,
  max_bytes: Int,
  max_agent_mailbox: Int,
  max_roots: Int,
  predicate: aql.AgentPredicate,
  privacy: types.Privacy,
  preset: types.Preset,
) -> Result(#(List(RawEvent), RawOutcome, types.ClockCalibration), String)

@external(erlang, "beamtrace_capture_ffi", "collect_distributed_spec")
fn collect_distributed_spec(
  nodes: List(String),
  cookie: String,
  module_: String,
  function_: String,
  arity: Int,
  capture_window_ms: Int,
  drain_timeout_ms: Int,
  max_events: Int,
  max_bytes: Int,
  max_agent_mailbox: Int,
  max_roots: Int,
  predicate: aql.AgentPredicate,
  privacy: types.Privacy,
  preset: types.Preset,
) -> Result(#(List(RawEvent), RawOutcome, types.ClockCalibration), String)

@external(erlang, "beamtrace_capture_ffi", "probe_remote")
fn probe_remote(node: String, cookie: String) -> Result(String, String)

@external(erlang, "beamtrace_capture_ffi", "search_remote")
fn search_remote(
  node: String,
  cookie: String,
  query: String,
  limit: Int,
) -> Result(List(MfaCandidate), String)

@external(erlang, "beamtrace_capture_ffi", "wait_remote_armed")
fn wait_remote_armed(
  node: String,
  cookie: String,
  timeout_ms: Int,
) -> Result(Nil, String)

@external(erlang, "beamtrace_capture_ffi", "wait_remote_available")
fn wait_remote_available(
  node: String,
  cookie: String,
  timeout_ms: Int,
) -> Result(Nil, String)
