import beamtrace/codec
import beamtrace/types
import beamtrace_runtime/storage
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
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
    <> "]}"
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
  <> "document.getElementById('summary').textContent=d.events.length+' causal events · '+d.manifest.completeness.kind;"
  <> "const b=document.getElementById('events');for(const e of d.events){const r=document.createElement('tr');"
  <> "for(const v of [e.id,e.event.kind,e.node,String(e.local_timestamp_ns)]){const c=document.createElement('td');c.textContent=v;r.appendChild(c)}b.appendChild(r)}"
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
    events -> "flowchart LR\n" <> mermaid_nodes(events, 0, [])
  }
}

/// OTLP/JSON export. Values are scrubbed to metadata by default; every event is
/// represented as a span-like record without claiming a synchronized global
/// wall-clock timestamp.
pub fn otlp(archive: storage.Archive, include_raw include_raw: Bool) -> String {
  let archive = case include_raw {
    True -> archive
    False -> scrub_archive(archive)
  }
  let exported_at_unix_ns = unix_time_nanoseconds()
  let node_latest = latest_node_timestamps(archive.events)
  json.object([
    #(
      "resourceSpans",
      json.array([archive], fn(archive) {
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
                    #("beamtrace.clock", "export-mapped-unix"),
                    #(
                      "beamtrace.otlp_time_mapping",
                      "export-time-minus-node-relative-age",
                    ),
                  ],
                  string_attribute,
                ),
              ),
            ]),
          ),
          #(
            "scopeSpans",
            json.array([archive.events], fn(events) {
              json.object([
                #("scope", json.object([#("name", json.string("beamtrace"))])),
                #(
                  "spans",
                  json.array(events, fn(event) {
                    otlp_span(event, exported_at_unix_ns, node_latest)
                  }),
                ),
              ])
            }),
          ),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn string_attribute(attribute: #(String, String)) -> json.Json {
  let #(key, value) = attribute
  json.object([
    #("key", json.string(key)),
    #("value", json.object([#("stringValue", json.string(value))])),
  ])
}

fn otlp_span(
  event: types.TraceEvent,
  exported_at_unix_ns: Int,
  node_latest: Dict(String, Int),
) -> json.Json {
  let latest = case dict.get(node_latest, event.node) {
    Ok(value) -> value
    Error(_) -> event.local_timestamp_ns
  }
  let relative_age = int.max(0, latest - event.local_timestamp_ns)
  let unix_timestamp = int.max(0, exported_at_unix_ns - relative_age)
  json.object([
    #("name", json.string(event_kind_name(event.kind))),
    #("spanId", json.string(event.id)),
    #("traceId", json.string(event.root_id)),
    #("startTimeUnixNano", json.string(int.to_string(unix_timestamp))),
    #(
      "attributes",
      json.array(
        [
          #("beamtrace.node", event.node),
          #("beamtrace.clock", "node-local"),
          #(
            "beamtrace.local_timestamp_ns",
            int.to_string(event.local_timestamp_ns),
          ),
          #("beamtrace.evidence", evidence_name(event.evidence)),
        ],
        string_attribute,
      ),
    ),
  ])
}

fn latest_node_timestamps(events: List(types.TraceEvent)) -> Dict(String, Int) {
  list.fold(events, dict.new(), fn(latest, event) {
    case dict.get(latest, event.node) {
      Error(_) -> dict.insert(latest, event.node, event.local_timestamp_ns)
      Ok(previous) ->
        dict.insert(
          latest,
          event.node,
          int.max(previous, event.local_timestamp_ns),
        )
    }
  })
}

@external(erlang, "beamtrace_export_ffi", "unix_time_nanoseconds")
fn unix_time_nanoseconds() -> Int

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
    types.Inferred(reason, _) -> "inferred:" <> reason
  }
}

fn mermaid_nodes(
  events: List(types.TraceEvent),
  index: Int,
  accumulator: List(String),
) -> String {
  case events {
    [] -> accumulator |> list.reverse |> string.concat
    [event] -> {
      let line =
        "  e"
        <> int.to_string(index)
        <> "[\""
        <> safe_label(event.id)
        <> "\"]\n"
      [line, ..accumulator] |> list.reverse |> string.concat
    }
    [event, ..rest] -> {
      let next_index = index + 1
      let node =
        "  e"
        <> int.to_string(index)
        <> "[\""
        <> safe_label(event.id)
        <> "\"]\n"
      let edge =
        "  e"
        <> int.to_string(index)
        <> " --> e"
        <> int.to_string(next_index)
        <> "\n"
      mermaid_nodes(rest, next_index, [edge, node, ..accumulator])
    }
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
  storage.Archive(
    codec.Manifest(..archive.manifest, privacy: types.Metadata),
    list.map(archive.events, scrub_event),
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
