// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string

pub fn decode(source: String) -> Result(workspace.EventPage, String) {
  case json.parse(source, page_decoder()) {
    Ok(page) -> Ok(page)
    Error(errors) -> Error(string.inspect(errors))
  }
}

fn page_decoder() -> decode.Decoder(workspace.EventPage) {
  use start <- decode.field("start", decode.int)
  use limit <- decode.field("limit", decode.int)
  use total <- decode.field("total", decode.int)
  use events <- decode.field("events", decode.list(event_decoder()))
  decode.success(workspace.EventPage(events, total, start, limit))
}

fn event_decoder() -> decode.Decoder(workspace.EventRow) {
  use id <- decode.field("id", decode.string)
  use actor <- decode.field("process", actor_decoder())
  use timestamp_ns <- decode.field("local_timestamp_ns", decode.int)
  use kind <- decode.field("event", kind_decoder())
  use evidence <- decode.field("evidence", evidence_decoder())
  decode.success(workspace.EventRow(
    id: id,
    actor: actor,
    kind: kind,
    timestamp_ns: timestamp_ns,
    duration_ns: 0,
    evidence: evidence,
    anomalous: kind == "exit" || kind == "gap",
    internal: is_internal(actor),
  ))
}

fn actor_decoder() -> decode.Decoder(String) {
  use physical <- decode.field("physical", physical_decoder())
  use logical <- decode.field("logical", decode.optional(logical_decoder()))
  decode.success(case logical {
    Some(label) -> label
    None -> physical
  })
}

fn physical_decoder() -> decode.Decoder(String) {
  use pid <- decode.field("pid", decode.string)
  decode.success(pid)
}

fn logical_decoder() -> decode.Decoder(String) {
  use label <- decode.field("label", decode.string)
  decode.success(label)
}

fn kind_decoder() -> decode.Decoder(String) {
  use kind <- decode.field("kind", decode.string)
  decode.success(kind)
}

fn evidence_decoder() -> decode.Decoder(workspace.Evidence) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "exact" -> decode.success(workspace.Exact)
    "inferred" -> {
      use reason <- decode.field("reason", decode.string)
      use confidence <- decode.field("confidence", decode.float)
      decode.success(workspace.Inferred(reason, confidence))
    }
    _ -> decode.failure(workspace.Exact, expected: "event evidence")
  }
}

fn is_internal(actor: String) -> Bool {
  let normalized = string.lowercase(actor)
  string.contains(normalized, "logger")
  || string.contains(normalized, "code_server")
  || string.contains(normalized, "beamtrace")
  || string.contains(normalized, "standard_io")
}
