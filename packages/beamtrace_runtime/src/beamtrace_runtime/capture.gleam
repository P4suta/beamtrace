import beamtrace/aql
import beamtrace/identity
import beamtrace/types
import gleam/dict
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

pub fn default_budget() -> Budget {
  Budget(100_000, 64_000_000, 10_000)
}

pub fn normalize(
  events: List(RawEvent),
  completeness: String,
  trigger: types.Mfa,
) -> CaptureResult {
  let normalized =
    list.map(events, fn(event) { normalize_event(event, trigger) })
  CaptureResult(
    events: propagate_process_identities(normalized),
    completeness: parse_completeness(completeness),
  )
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
    RawEventWithMetadata(_, _, _, _, _, _, _, _, _, _, metadata) ->
      identity.resolve(physical, process_metadata(metadata))
  }
  let peer = types.ProcessRef(event.peer_node, event.peer_pid)
  let message = types.Tag(event.semantic)
  let kind = case event.kind {
    "root" -> types.Root(trigger, [])
    "send" -> types.Send(peer, message, event.serial)
    "receive" -> types.Received(peer, message, event.serial)
    "print" -> types.SystemSignal("seq_trace_print", event.serial)
    "spawn" ->
      case parse_mfa(event.semantic) {
        Ok(initial_call) -> types.Spawn(peer, initial_call)
        Error(_) -> types.Gap(1, "invalid spawn initial call")
      }
    "exit" -> types.Exit(types.Tag(event.semantic))
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
  ]
  let specific = case event.kind {
    types.Root(_, _) -> [
      #("mfa", aql.StringValue(mfa_name(trigger))),
      #("module", aql.StringValue(trigger.module_)),
      #("function", aql.StringValue(trigger.function_)),
      #("arity", aql.IntValue(trigger.arity)),
    ]
    types.Send(_, message, _) | types.Received(_, message, _) ->
      case message_tag(message) {
        "" -> []
        tag -> [#("message.tag", aql.StringValue(tag))]
      }
    _ -> []
  }
  dict.from_list(list.append(common, specific))
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
  let types.Mfa(module_, function_, arity) = trigger
  use payload <- try_result(collect_remote(
    node,
    cookie,
    module_,
    function_,
    arity,
    capture_window_ms,
    budget.max_events,
    budget.max_bytes,
    budget.max_agent_mailbox,
  ))
  let #(events, completeness) = payload
  Ok(normalize(events, completeness, trigger))
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
      let types.Mfa(module_, function_, arity) = trigger
      use payload <- try_result(collect_distributed(
        nodes,
        cookie,
        module_,
        function_,
        arity,
        capture_window_ms,
        budget.max_events,
        budget.max_bytes,
        budget.max_agent_mailbox,
      ))
      let #(events, completeness) = payload
      Ok(normalize(events, completeness, trigger))
    }
  }
}

pub fn probe(node: String, cookie: String) -> Result(String, String) {
  probe_remote(node, cookie)
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

@external(erlang, "beamtrace_capture_ffi", "collect_remote")
fn collect_remote(
  node: String,
  cookie: String,
  module_: String,
  function_: String,
  arity: Int,
  capture_window_ms: Int,
  max_events: Int,
  max_bytes: Int,
  max_agent_mailbox: Int,
) -> Result(#(List(RawEvent), String), String)

@external(erlang, "beamtrace_capture_ffi", "collect_distributed")
fn collect_distributed(
  nodes: List(String),
  cookie: String,
  module_: String,
  function_: String,
  arity: Int,
  capture_window_ms: Int,
  max_events: Int,
  max_bytes: Int,
  max_agent_mailbox: Int,
) -> Result(#(List(RawEvent), String), String)

@external(erlang, "beamtrace_capture_ffi", "probe_remote")
fn probe_remote(node: String, cookie: String) -> Result(String, String)
