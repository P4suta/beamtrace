import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type DiffItem {
  Matched(left_id: String, right_id: String, latency_delta_ns: Int)
  Added(right_id: String)
  Removed(left_id: String)
  Changed(left_id: String, right_id: String, reason: String)
}

pub type DiffReport {
  DiffReport(items: List(DiffItem), added: Int, removed: Int, changed: Int)
}

/// Align two causal sequences by logical actor and term shape. Physical PIDs,
/// node-local timestamps, seq_trace serials, scalar values, and fingerprints
/// are deliberately absent from the alignment signature.
pub fn compare(
  left: List(types.TraceEvent),
  right: List(types.TraceEvent),
) -> DiffReport {
  let items = align(left, right, left, right, []) |> list.reverse
  DiffReport(
    items: items,
    added: count_added(items),
    removed: count_removed(items),
    changed: count_changed(items),
  )
}

fn align(
  left: List(types.TraceEvent),
  right: List(types.TraceEvent),
  left_run: List(types.TraceEvent),
  right_run: List(types.TraceEvent),
  accumulator: List(DiffItem),
) -> List(DiffItem) {
  case left, right {
    [], [] -> accumulator
    [], [right, ..right_rest] ->
      align([], right_rest, left_run, right_run, [
        Added(right.id),
        ..accumulator
      ])
    [left, ..left_rest], [] ->
      align(left_rest, [], left_run, right_run, [
        Removed(left.id),
        ..accumulator
      ])
    [left, ..left_rest], [right, ..right_rest] -> {
      let left_signature = signature(left)
      let right_signature = signature(right)
      case left_signature == right_signature {
        True ->
          align(left_rest, right_rest, left_run, right_run, [
            Matched(
              left_id: left.id,
              right_id: right.id,
              latency_delta_ns: relative_time(right, right_run)
                - relative_time(left, left_run),
            ),
            ..accumulator
          ])
        False ->
          case
            contains_signature(right_rest, left_signature),
            contains_signature(left_rest, right_signature)
          {
            True, _ ->
              align([left, ..left_rest], right_rest, left_run, right_run, [
                Added(right.id),
                ..accumulator
              ])
            _, True ->
              align(left_rest, [right, ..right_rest], left_run, right_run, [
                Removed(left.id),
                ..accumulator
              ])
            _, _ ->
              align(left_rest, right_rest, left_run, right_run, [
                Changed(left.id, right.id, "logical event shape differs"),
                ..accumulator
              ])
          }
      }
    }
  }
}

fn relative_time(event: types.TraceEvent, run: List(types.TraceEvent)) -> Int {
  event.local_timestamp_ns
  - root_origin(run, event.root_id, None, event.local_timestamp_ns)
}

fn root_origin(
  events: List(types.TraceEvent),
  root_id: String,
  found: Option(Int),
  fallback: Int,
) -> Int {
  case events {
    [] ->
      case found {
        Some(value) -> value
        None -> fallback
      }
    [event, ..rest] -> {
      let found = case event.root_id == root_id, found {
        False, _ -> found
        True, None -> Some(event.local_timestamp_ns)
        True, Some(value) ->
          case event.local_timestamp_ns < value {
            True -> Some(event.local_timestamp_ns)
            False -> found
          }
      }
      root_origin(rest, root_id, found, fallback)
    }
  }
}

fn contains_signature(events: List(types.TraceEvent), wanted: String) -> Bool {
  list.any(events, fn(event) { signature(event) == wanted })
}

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
    let #(key, value) = entry
    view_signature(key) <> "=" <> view_signature(value)
  })
  |> string.join(",")
}

fn count_added(items: List(DiffItem)) -> Int {
  items
  |> list.filter(fn(item) {
    case item {
      Added(_) -> True
      _ -> False
    }
  })
  |> list.length
}

fn count_removed(items: List(DiffItem)) -> Int {
  items
  |> list.filter(fn(item) {
    case item {
      Removed(_) -> True
      _ -> False
    }
  })
  |> list.length
}

fn count_changed(items: List(DiffItem)) -> Int {
  items
  |> list.filter(fn(item) {
    case item {
      Changed(_, _, _) -> True
      _ -> False
    }
  })
  |> list.length
}
