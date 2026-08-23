import beamtrace/aql
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

pub type CaptureResult {
  CaptureResult(
    events: List(types.TraceEvent),
    completeness: types.Completeness,
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
  let #(events, completeness) = payload
  let result = normalize(events, completeness, spec.trigger)
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
    budget.max_agent_mailbox > 0,
    budget.max_roots > 0 && budget.max_roots <= 1000,
    valid_privacy(spec.privacy)
  {
    [], _, _, _, _, _, _, _, _ -> Error("capture_requires_at_least_one_node")
    _, False, _, _, _, _, _, _, _ -> Error("too_many_capture_nodes")
    _, _, False, _, _, _, _, _, _ -> Error("duplicate_capture_node")
    _, _, _, False, _, _, _, _, _ -> Error("invalid_event_budget")
    _, _, _, _, False, _, _, _, _ -> Error("invalid_byte_budget")
    _, _, _, _, _, False, _, _, _ -> Error("invalid_capture_window")
    _, _, _, _, _, _, False, _, _ -> Error("invalid_mailbox_budget")
    _, _, _, _, _, _, _, False, _ -> Error("invalid_root_budget")
    _, _, _, _, _, _, _, _, False -> Error("invalid_privacy_policy")
    _, True, True, True, True, True, True, True, True -> Ok(Nil)
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
  let normalized =
    list.map(events, fn(event) { normalize_event(event, trigger) })
  CaptureResult(
    events: normalized |> disambiguate_roots |> propagate_process_identities,
    completeness: parse_completeness(completeness),
  )
}

fn disambiguate_roots(
  events: List(types.TraceEvent),
) -> List(types.TraceEvent) {
  let root_counts =
    list.fold(events, dict.new(), fn(counts, event) {
      case event.kind {
        types.Root(_, _) ->
          dict.insert(
            counts,
            event.root_id,
            case dict.get(counts, event.root_id) {
              Ok(count) -> count + 1
              Error(_) -> 1
            },
          )
        _ -> counts
      }
    })
  let #(_, reversed) =
    list.fold(events, #(dict.new(), []), fn(state, event) {
      let #(process_roots, accumulator) = state
      let ambiguous = case dict.get(root_counts, event.root_id) {
        Ok(count) -> count > 1
        Error(_) -> False
      }
      case event.kind, ambiguous {
        types.Root(_, _), True -> {
          let root_id = event.id
          #(
            dict.insert(
              process_roots,
              process_key(event.process.physical),
              root_id,
            ),
            [types.TraceEvent(..event, root_id: root_id), ..accumulator],
          )
        }
        types.Root(_, _), False -> #(
          dict.insert(
            process_roots,
            process_key(event.process.physical),
            event.root_id,
          ),
          [event, ..accumulator],
        )
        _, False -> #(
          propagate_root_to_peer(process_roots, event, event.root_id),
          [event, ..accumulator],
        )
        _, True -> {
          let assigned = case
            dict.get(process_roots, process_key(event.process.physical))
          {
            Ok(root_id) -> Ok(root_id)
            Error(_) -> root_from_peer(process_roots, event)
          }
          case assigned {
            Ok(root_id) -> #(
              propagate_root_to_peer(process_roots, event, root_id),
              [types.TraceEvent(..event, root_id: root_id), ..accumulator],
            )
            Error(_) -> #(process_roots, [
              types.TraceEvent(
                ..event,
                root_id: "unattributed:" <> event.root_id,
                evidence: types.inferred(
                  "multiple root attribution unavailable",
                  0.0,
                ),
              ),
              ..accumulator
            ])
          }
        }
      }
    })
  list.reverse(reversed)
}

fn root_from_peer(
  process_roots: Dict(String, String),
  event: types.TraceEvent,
) -> Result(String, Nil) {
  case event.kind {
    types.Received(from, _, _) -> dict_root(process_roots, from)
    _ -> Error(Nil)
  }
}

fn propagate_root_to_peer(
  process_roots: Dict(String, String),
  event: types.TraceEvent,
  root_id: String,
) -> Dict(String, String) {
  let with_process =
    dict.insert(process_roots, process_key(event.process.physical), root_id)
  case event.kind {
    types.Send(to, _, _) | types.Spawn(to, _) ->
      insert_root_if_absent(with_process, to, root_id)
    _ -> with_process
  }
}

fn insert_root_if_absent(
  roots: Dict(String, String),
  process: types.ProcessRef,
  root_id: String,
) -> Dict(String, String) {
  case dict_root(roots, process) {
    Ok(_) -> roots
    Error(_) -> dict.insert(roots, process_key(process), root_id)
  }
}

fn dict_root(
  roots: Dict(String, String),
  process: types.ProcessRef,
) -> Result(String, Nil) {
  case dict.get(roots, process_key(process)) {
    Ok(root_id) -> Ok(root_id)
    Error(_) -> Error(Nil)
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
    RawEvent(_, _, _, _, _, _, _, _, _, _) ->
      types.ProcessIdentity(physical: physical, logical: None, evidence: [])
    RawEventWithMetadata(_, _, _, _, _, _, _, _, _, _, metadata)
    | RawEventWithTerm(_, _, _, _, _, _, _, _, _, _, metadata, _) ->
      identity.resolve(physical, process_metadata(metadata))
  }
  let peer = types.ProcessRef(event.peer_node, event.peer_pid)
  let message = shaped_term(event, types.Tag(event.semantic))
  let kind = case event.kind {
    "root" -> types.Root(trigger, root_arguments(event))
    "send" -> types.Send(peer, message, event.serial)
    "receive" -> types.Received(peer, message, event.serial)
    "print" -> types.SystemSignal("seq_trace_print", event.serial)
    "spawn" ->
      case parse_mfa(event.semantic) {
        Ok(initial_call) -> types.Spawn(peer, initial_call)
        Error(_) -> types.Gap(1, "invalid spawn initial call")
      }
    "exit" -> types.Exit(message)
    "register" -> types.Register(event.semantic)
    "link" -> types.Link(peer)
    "gap" -> types.Gap(1, "relay backpressure")
    unknown -> types.Gap(1, "unknown relay event: " <> unknown)
  }

  types.TraceEvent(
    id: event.id,
    root_id: event.root_id,
    node: event.node,
    process: process,
    local_timestamp_ns: event.local_timestamp_ns,
    kind: kind,
    evidence: types.Exact,
  )
}

fn shaped_term(event: RawEvent, fallback: types.TermView) -> types.TermView {
  case event {
    RawEventWithTerm(_, _, _, _, _, _, _, _, _, _, _, term) ->
      normalize_term(term)
    _ -> fallback
  }
}

fn root_arguments(event: RawEvent) -> List(types.TermView) {
  case event {
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

pub fn parse_completeness(source: String) -> types.Completeness {
  case source {
    "complete" -> types.Complete
    _ ->
      case string.split_once(source, ":") {
        Ok(#("truncated", reason)) -> types.Truncated(reason)
        Ok(#("gapped", count)) ->
          case int.parse(count) {
            Ok(value) -> types.Gapped(value)
            Error(_) -> types.Gapped(1)
          }
        Ok(#("partial_node", nodes)) ->
          types.PartialNode(string.split(nodes, on: ","))
        Ok(#("inferred", reason)) -> types.InferredCapture(reason)
        _ -> types.InferredCapture("unknown completeness: " <> source)
      }
  }
}

pub fn exit_code(completeness: types.Completeness) -> Int {
  case completeness {
    types.Complete -> 0
    types.Truncated(_)
    | types.Gapped(_)
    | types.PartialNode(_)
    | types.InferredCapture(_) -> 3
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
    #("timestamp_ns", aql.IntValue(event.local_timestamp_ns)),
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
  max_events: Int,
  max_bytes: Int,
  max_agent_mailbox: Int,
  max_roots: Int,
  predicate: aql.AgentPredicate,
  privacy: types.Privacy,
  preset: types.Preset,
) -> Result(#(List(RawEvent), String), String)

@external(erlang, "beamtrace_capture_ffi", "collect_distributed_spec")
fn collect_distributed_spec(
  nodes: List(String),
  cookie: String,
  module_: String,
  function_: String,
  arity: Int,
  capture_window_ms: Int,
  max_events: Int,
  max_bytes: Int,
  max_agent_mailbox: Int,
  max_roots: Int,
  predicate: aql.AgentPredicate,
  privacy: types.Privacy,
  preset: types.Preset,
) -> Result(#(List(RawEvent), String), String)

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
