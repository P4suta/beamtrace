import beamtrace/codec
import beamtrace/dag
import beamtrace/merge
import beamtrace/types
import beamtrace_runtime/crypto
import beamtrace_runtime/storage
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn html(archive: storage.Archive, include_raw include_raw: Bool) -> String {
  let safe_archive = case include_raw {
    True -> archive
    False -> scrub_archive(archive)
  }
  let payload =
    "{\"manifest\":"
    <> codec.encode_manifest(safe_archive.manifest)
    <> ",\"events\":["
    <> {
      safe_archive.events |> list.map(codec.encode_event) |> string.join(",")
    }
    <> "],\"graph\":"
    <> codec.encode_graph_segment(codec.GraphSegment(
      event_ids: list.map(safe_archive.events, fn(event) { event.id }),
      edges: safe_archive.graph.edges,
      boundaries: safe_archive.graph.boundaries,
    ))
    <> ",\"clocks\":"
    <> codec.encode_clocks(safe_archive.clocks)
    <> "}"
    |> script_safe

  "<!doctype html>\n"
  <> "<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
  <> "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'\">"
  <> "<title>BeamTrace trace</title><style>"
  <> ":root{color-scheme:dark;background:#111015;color:#f6ecdc;font:14px system-ui,sans-serif}"
  <> "body{margin:0;padding:24px}h1{color:#ffb347}table{width:100%;border-collapse:collapse}"
  <> "th,td{text-align:left;padding:8px;border-bottom:1px solid #40384d}th{color:#ca9cff}"
  <> "code{color:#ff887a}</style></head><body><main>"
  <> "<h1>BeamTrace trace</h1><p id=\"summary\"></p>"
  <> "<table aria-label=\"Causal events\"><thead><tr><th>Event</th><th>Kind</th><th>Node</th><th>Time</th></tr></thead><tbody id=\"events\"></tbody></table>"
  <> "</main><script type=\"application/json\" id=\"beamtrace-trace\">"
  <> payload
  <> "</script><script>"
  <> "const d=JSON.parse(document.getElementById('beamtrace-trace').textContent);"
  <> "document.getElementById('summary').textContent=d.events.length+' causal events · '+d.manifest.outcome.end.kind;"
  <> "const b=document.getElementById('events');for(const e of d.events){const r=document.createElement('tr');"
  <> "for(const v of [e.id,e.event.kind,e.node,String(e.local_instant.offset_ns)]){const c=document.createElement('td');c.textContent=v;r.appendChild(c)}b.appendChild(r)}"
  <> "</script></body></html>\n"
}

pub fn jsonl(
  archive: storage.Archive,
  include_raw include_raw: Bool,
) -> String {
  let archive = case include_raw {
    True -> archive
    False -> scrub_archive(archive)
  }
  archive.events
  |> list.map(codec.encode_event)
  |> string.join("\n")
  |> fn(body) {
    case body == "" {
      True -> ""
      False -> body <> "\n"
    }
  }
}

pub fn mermaid(archive: storage.Archive) -> String {
  case archive.events {
    [] -> "flowchart LR\n  empty[\"No captured events\"]\n"
    events -> {
      let #(indexes, nodes) = mermaid_nodes(events, 0, dict.new(), [])
      "flowchart LR\n"
      <> nodes
      <> mermaid_edges(archive.graph.edges, indexes, [])
      <> mermaid_boundaries(archive.graph.boundaries, indexes, 0, [])
    }
  }
}

type ExportEvent {
  ExportEvent(event: types.TraceEvent, time: types.TimeEstimate)
}

/// Standards-shaped OTLP/JSON export. Capture-time clock probes are mandatory.
/// A v1 archive can only be exported with the explicit legacy anchor override.
pub fn otlp(
  archive: storage.Archive,
  include_raw include_raw: Bool,
  anchor_now anchor_now: Bool,
) -> Result(String, String) {
  let archive = case include_raw {
    True -> archive
    False -> scrub_archive(archive)
  }
  use positioned <- result.try(position_for_otlp(archive, anchor_now))
  let event_index =
    list.fold(archive.events, dict.new(), fn(index, event) {
      dict.insert(index, event.id, event)
    })
  let incoming = incoming_edges(archive.graph.edges)
  let clock_policy = case archive.manifest.schema_version, anchor_now {
    1, True -> "explicit-legacy-anchor-now"
    _, _ -> "capture-calibration"
  }
  Ok(
    json.object([
      #(
        "resourceSpans",
        json.array([positioned], fn(events) {
          json.object([
            #(
              "resource",
              json.object([
                #(
                  "attributes",
                  json.array(
                    [
                      #("service.name", "beamtrace"),
                      #("beamtrace.capture_id", archive.manifest.capture_id),
                      #(
                        "beamtrace.schema_version",
                        int.to_string(archive.manifest.schema_version),
                      ),
                      #("beamtrace.clock", clock_policy),
                    ],
                    string_attribute,
                  ),
                ),
              ]),
            ),
            #(
              "scopeSpans",
              json.array([events], fn(events) {
                json.object([
                  #("scope", json.object([#("name", json.string("beamtrace"))])),
                  #(
                    "spans",
                    json.array(events, fn(positioned) {
                      otlp_span(
                        positioned,
                        archive.manifest.capture_id,
                        event_index,
                        dict.get(incoming, positioned.event.id)
                          |> result.unwrap([]),
                      )
                    }),
                  ),
                ])
              }),
            ),
          ])
        }),
      ),
    ])
    |> json.to_string,
  )
}

fn string_attribute(attribute: #(String, String)) -> json.Json {
  let #(key, value) = attribute
  json.object([
    #("key", json.string(key)),
    #("value", json.object([#("stringValue", json.string(value))])),
  ])
}

fn otlp_span(
  positioned: ExportEvent,
  capture_id: String,
  event_index: Dict(String, types.TraceEvent),
  incoming: List(types.CausalEdge),
) -> json.Json {
  let event = positioned.event
  let #(center, lower, upper, time_kind) = estimate_parts(positioned.time)
  let trace_id = trace_id(capture_id, event.root_id)
  let parent = select_parent(event, incoming, event_index)
  let links = case parent {
    None -> incoming
    Some(parent) -> list.filter(incoming, fn(edge) { edge != parent })
  }
  let base = [
    #("name", json.string(event_kind_name(event.kind))),
    #("spanId", json.string(span_id(capture_id, event.id))),
    #("traceId", json.string(trace_id)),
    #("startTimeUnixNano", json.string(int.to_string(center))),
    #("endTimeUnixNano", json.string(int.to_string(center))),
    #(
      "links",
      json.array(links, fn(edge) { otlp_link(edge, capture_id, event_index) }),
    ),
    #(
      "attributes",
      json.array(
        [
          #("beamtrace.event_id", event.id),
          #("beamtrace.root_id", event.root_id),
          #("beamtrace.node", event.node),
          #("beamtrace.time.kind", time_kind),
          #("beamtrace.time.lower_unix_ns", int.to_string(lower)),
          #("beamtrace.time.upper_unix_ns", int.to_string(upper)),
          #(
            "beamtrace.local_offset_ns",
            int.to_string(event.local_instant.offset_ns),
          ),
          #("beamtrace.local_order", int.to_string(event.local_instant.order)),
          #("beamtrace.evidence", evidence_name(event.evidence)),
          #(
            "beamtrace.evidence_json",
            codec.evidence_json(event.evidence) |> json.to_string,
          ),
        ],
        string_attribute,
      ),
    ),
  ]
  let fields = case parent {
    None -> base
    Some(edge) -> [
      #("parentSpanId", json.string(span_id(capture_id, edge.from))),
      ..base
    ]
  }
  json.object(fields)
}

fn position_for_otlp(
  archive: storage.Archive,
  anchor_now: Bool,
) -> Result(List(ExportEvent), String) {
  case archive.manifest.schema_version, anchor_now {
    1, False ->
      Error(
        "v1_clock_information_unavailable; pass --otlp-anchor-now to accept an explicit synthetic anchor",
      )
    1, True ->
      legacy_anchor_times(
        archive.events,
        node_origins(archive.events),
        unix_time_nanoseconds(),
      )
    _, True -> Error("--otlp-anchor-now is only valid for a legacy v1 archive")
    _, False
      if archive.clocks.capture_anchor_unix_ns <= 0 || archive.clocks.nodes == []
    -> Error("capture_clock_calibration_unavailable")
    _, False -> calibrated_times(archive.events, archive.clocks, [])
  }
}

@external(erlang, "beamtrace_export_ffi", "unix_time_nanoseconds")
fn unix_time_nanoseconds() -> Int

fn calibrated_times(
  events: List(types.TraceEvent),
  clocks: types.ClockCalibration,
  accumulator: List(ExportEvent),
) -> Result(List(ExportEvent), String) {
  case events {
    [] -> Ok(list.reverse(accumulator))
    [event, ..rest] -> {
      let estimate = merge.calibrated_time(event, clocks)
      use Nil <- result.try(validate_otlp_time(event.id, estimate))
      calibrated_times(rest, clocks, [
        ExportEvent(event, estimate),
        ..accumulator
      ])
    }
  }
}

fn legacy_anchor_times(
  events: List(types.TraceEvent),
  origins: Dict(String, Int),
  anchor: Int,
) -> Result(List(ExportEvent), String) {
  events
  |> list.map(fn(event) {
    let origin = dict.get(origins, event.node) |> result.unwrap(0)
    let value = anchor + event.local_instant.offset_ns - origin
    ExportEvent(event, types.EstimatedTime(value, value, value))
  })
  |> Ok
}

fn node_origins(events: List(types.TraceEvent)) -> Dict(String, Int) {
  list.fold(events, dict.new(), fn(origins, event) {
    case dict.get(origins, event.node) {
      Error(_) ->
        dict.insert(origins, event.node, event.local_instant.offset_ns)
      Ok(origin) ->
        dict.insert(
          origins,
          event.node,
          int.min(origin, event.local_instant.offset_ns),
        )
    }
  })
}

fn validate_otlp_time(
  event_id: String,
  estimate: types.TimeEstimate,
) -> Result(Nil, String) {
  case estimate {
    types.ExactTime(value) if value >= 0 -> Ok(Nil)
    types.EstimatedTime(value, lower, upper)
      if lower >= 0 && lower <= value && value <= upper
    -> Ok(Nil)
    types.TimeUnavailable(reason) ->
      Error("clock_unavailable_for_event:" <> event_id <> ":" <> reason)
    _ -> Error("invalid_unix_time_for_event:" <> event_id)
  }
}

fn estimate_parts(estimate: types.TimeEstimate) -> #(Int, Int, Int, String) {
  case estimate {
    types.ExactTime(value) -> #(value, value, value, "exact")
    types.EstimatedTime(value, lower, upper) -> #(
      value,
      lower,
      upper,
      "estimated",
    )
    types.TimeUnavailable(_) -> #(0, 0, 0, "unavailable")
  }
}

fn incoming_edges(
  edges: List(types.CausalEdge),
) -> Dict(String, List(types.CausalEdge)) {
  list.fold(edges, dict.new(), fn(index, edge) {
    let existing = dict.get(index, edge.to) |> result.unwrap([])
    dict.insert(index, edge.to, [edge, ..existing])
  })
}

fn select_parent(
  event: types.TraceEvent,
  incoming: List(types.CausalEdge),
  event_index: Dict(String, types.TraceEvent),
) -> Option(types.CausalEdge) {
  case event.kind {
    types.Root(_, _) -> None
    _ ->
      incoming
      |> list.find(fn(edge) {
        edge.evidence == types.Exact
        && case dict.get(event_index, edge.from) {
          Ok(source) -> source.root_id == event.root_id
          Error(_) -> False
        }
      })
      |> fn(found) {
        case found {
          Ok(edge) -> Some(edge)
          Error(_) -> None
        }
      }
  }
}

fn otlp_link(
  edge: types.CausalEdge,
  capture_id: String,
  event_index: Dict(String, types.TraceEvent),
) -> json.Json {
  let linked_trace_id = case dict.get(event_index, edge.from) {
    Ok(source) -> trace_id(capture_id, source.root_id)
    Error(_) -> trace_id(capture_id, "boundary")
  }
  json.object([
    #("traceId", json.string(linked_trace_id)),
    #("spanId", json.string(span_id(capture_id, edge.from))),
    #(
      "attributes",
      json.array(
        [
          #("beamtrace.edge.kind", edge_kind_name(edge.kind)),
          #("beamtrace.edge.evidence", evidence_name(edge.evidence)),
        ],
        string_attribute,
      ),
    ),
  ])
}

fn trace_id(capture_id: String, root_id: String) -> String {
  crypto.sha256_hex("beamtrace-otlp-trace\n" <> capture_id <> "\n" <> root_id)
  |> string.slice(at_index: 0, length: 32)
}

fn span_id(capture_id: String, event_id: String) -> String {
  crypto.sha256_hex("beamtrace-otlp-span\n" <> capture_id <> "\n" <> event_id)
  |> string.slice(at_index: 0, length: 16)
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
    types.Metric(name, _) -> "metric:" <> name
    types.SystemSignal(name, _) -> "system:" <> name
    types.Gap(_, _) -> "gap"
    types.Stop(_) -> "stop"
  }
}

fn evidence_name(evidence: types.Evidence) -> String {
  case evidence {
    types.Exact -> "exact"
    types.Inferred(inference) -> "inferred:" <> inference.method
  }
}

fn mermaid_nodes(
  events: List(types.TraceEvent),
  index: Int,
  indexes: Dict(String, Int),
  accumulator: List(String),
) -> #(Dict(String, Int), String) {
  case events {
    [] -> #(indexes, accumulator |> list.reverse |> string.concat)
    [event, ..rest] -> {
      let node =
        "  e"
        <> int.to_string(index)
        <> "[\""
        <> safe_label(event.id)
        <> "\"]\n"
      mermaid_nodes(rest, index + 1, dict.insert(indexes, event.id, index), [
        node,
        ..accumulator
      ])
    }
  }
}

fn mermaid_edges(
  edges: List(types.CausalEdge),
  indexes: Dict(String, Int),
  accumulator: List(String),
) -> String {
  case edges {
    [] -> accumulator |> list.reverse |> string.concat
    [edge, ..rest] ->
      case dict.get(indexes, edge.from), dict.get(indexes, edge.to) {
        Ok(from), Ok(to) -> {
          let arrow = case edge.evidence {
            types.Exact -> " --> "
            types.Inferred(_) -> " -.-> "
          }
          let line =
            "  e"
            <> int.to_string(from)
            <> arrow
            <> "|"
            <> edge_kind_name(edge.kind)
            <> "| e"
            <> int.to_string(to)
            <> "\n"
          mermaid_edges(rest, indexes, [line, ..accumulator])
        }
        _, _ -> mermaid_edges(rest, indexes, accumulator)
      }
  }
}

fn mermaid_boundaries(
  boundaries: List(types.Boundary),
  indexes: Dict(String, Int),
  boundary_index: Int,
  accumulator: List(String),
) -> String {
  case boundaries {
    [] -> accumulator |> list.reverse |> string.concat
    [boundary, ..rest] ->
      case dict.get(indexes, boundary.event_id) {
        Error(_) ->
          mermaid_boundaries(rest, indexes, boundary_index, accumulator)
        Ok(event_index) -> {
          let suffix = int.to_string(boundary_index)
          let line =
            "  b"
            <> suffix
            <> "((\"boundary: "
            <> safe_label(boundary.reason)
            <> "\"))\n  e"
            <> int.to_string(event_index)
            <> " -.- b"
            <> suffix
            <> "\n"
          mermaid_boundaries(rest, indexes, boundary_index + 1, [
            line,
            ..accumulator
          ])
        }
      }
  }
}

fn edge_kind_name(kind: types.EdgeKind) -> String {
  case kind {
    types.SequentialMessage(_) -> "message"
    types.ProcessOrder -> "process"
    types.Spawned -> "spawn"
    types.LinkRelationship -> "link"
    types.InferredRelation(_) -> "inferred"
    types.ExternalBoundary -> "boundary"
    types.UnobservedState -> "unobserved"
  }
}

fn safe_label(value: String) -> String {
  value |> string.replace("\"", "'") |> string.replace("\n", " ")
}

fn script_safe(value: String) -> String {
  value
  |> string.replace("&", "\\u0026")
  |> string.replace("<", "\\u003c")
  |> string.replace(">", "\\u003e")
}

fn scrub_archive(archive: storage.Archive) -> storage.Archive {
  let events = list.map(archive.events, scrub_event)
  storage.Archive(
    codec.Manifest(..archive.manifest, privacy: types.Metadata),
    events,
    dag.CausalGraph(..archive.graph, events: events),
    archive.clocks,
  )
}

fn scrub_event(event: types.TraceEvent) -> types.TraceEvent {
  types.TraceEvent(..event, kind: scrub_kind(event.kind))
}

fn scrub_kind(kind: types.TraceEventKind) -> types.TraceEventKind {
  case kind {
    types.Root(mfa, arguments) ->
      types.Root(mfa, list.map(arguments, scrub_term))
    types.Send(to, message, serial) ->
      types.Send(to, scrub_term(message), serial)
    types.Received(from, message, serial) ->
      types.Received(from, scrub_term(message), serial)
    types.Exit(reason) -> types.Exit(scrub_term(reason))
    other -> other
  }
}

fn scrub_term(term: types.TermView) -> types.TermView {
  case term {
    types.Tuple(items) -> types.Tuple(list.map(items, scrub_term))
    types.Constructor(name, fields) ->
      types.Constructor(name, list.map(fields, scrub_term))
    types.ListView(length, items) ->
      types.ListView(length, list.map(items, scrub_term))
    types.MapView(size, entries) ->
      types.MapView(
        size,
        list.map(entries, fn(entry) {
          let #(key, value) = entry
          #(scrub_term(key), scrub_term(value))
        }),
      )
    types.BinaryMetadata(bytes, _, fingerprint) ->
      types.BinaryMetadata(bytes, None, fingerprint)
    types.Scalar(kind, _, fingerprint) -> types.Scalar(kind, None, fingerprint)
    other -> other
  }
}
