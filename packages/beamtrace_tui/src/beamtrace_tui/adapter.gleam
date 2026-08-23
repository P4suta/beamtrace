// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_tui/model
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub fn from_trace(events: List(types.TraceEvent)) -> List(model.Event) {
  case events {
    [] -> []
    [first, ..] ->
      list.map(events, fn(event) { from_event(event, first.local_timestamp_ns) })
  }
}

fn from_event(event: types.TraceEvent, origin_ns: Int) -> model.Event {
  model.Event(
    id: event.id,
    actor: actor_name(event.process),
    kind: kind_name(event.kind),
    evidence: evidence_name(event.evidence),
    offset_us: int.max(0, event.local_timestamp_ns - origin_ns) / 1000,
    anomalous: anomalous(event.kind),
  )
}

fn actor_name(identity: types.ProcessIdentity) -> String {
  case identity.logical {
    Some(actor) -> actor.label
    None -> identity.physical.pid
  }
}

fn kind_name(kind: types.TraceEventKind) -> String {
  case kind {
    types.Root(trigger, _) -> "call " <> mfa_name(trigger)
    types.Send(_, _, _) -> "send"
    types.Received(_, _, _) -> "receive"
    types.Spawn(_, _) -> "spawn"
    types.Exit(_) -> "exit"
    types.Register(name) -> "register " <> name
    types.Link(_) -> "link"
    types.Metric(name, _) -> "metric " <> name
    types.SystemSignal(name, _) -> name
    types.Gap(_, _) -> "gap"
    types.Stop(_) -> "stop"
  }
}

fn evidence_name(evidence: types.Evidence) -> String {
  case evidence {
    types.Exact -> "Exact"
    types.Inferred(reason, confidence) ->
      "Inferred " <> float.to_string(confidence) <> " · " <> reason
  }
}

fn anomalous(kind: types.TraceEventKind) -> Bool {
  case kind {
    types.Exit(_) | types.Gap(_, _) -> True
    types.SystemSignal(name, _) ->
      string.contains(string.lowercase(name), "restart")
      || string.contains(string.lowercase(name), "long_gc")
      || string.contains(string.lowercase(name), "busy")
    _ -> False
  }
}

fn mfa_name(mfa: types.Mfa) -> String {
  mfa.module_ <> ":" <> mfa.function_ <> "/" <> int.to_string(mfa.arity)
}
