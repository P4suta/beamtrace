// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/int
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

/// Decode the API v2 observation/time wrapper. Flat v2 and v1 events remain a
/// read-only compatibility input for Team traces created by older relays.
pub fn event_decoder() -> decode.Decoder(workspace.EventRow) {
  decode.one_of(v2_page_event_decoder(), or: [
    flat_v2_event_decoder(),
    flat_v1_event_decoder(),
  ])
}

fn v2_page_event_decoder() -> decode.Decoder(workspace.EventRow) {
  use row <- decode.field("observation", flat_v2_event_decoder())
  use time <- decode.field("time", time_estimate_decoder())
  decode.success(workspace.EventRow(..row, time: time))
}

fn flat_v2_event_decoder() -> decode.Decoder(workspace.EventRow) {
  use id <- decode.field("id", decode.string)
  use actor <- decode.field("process", actor_decoder())
  use timestamp_ns <- decode.field("local_instant", local_offset_decoder())
  use kind <- decode.field("event", kind_decoder())
  use evidence <- decode.field("evidence", evidence_decoder())
  decode.success(event_row(
    id,
    actor,
    timestamp_ns,
    kind,
    workspace.TimeUnavailable("calibrated time was not supplied"),
    evidence,
  ))
}

fn flat_v1_event_decoder() -> decode.Decoder(workspace.EventRow) {
  use id <- decode.field("id", decode.string)
  use actor <- decode.field("process", actor_decoder())
  use timestamp_ns <- decode.field("local_timestamp_ns", decode.int)
  use kind <- decode.field("event", kind_decoder())
  use evidence <- decode.field("evidence", legacy_evidence_decoder())
  decode.success(event_row(
    id,
    actor,
    timestamp_ns,
    kind,
    workspace.TimeUnavailable("legacy trace has no clock calibration"),
    evidence,
  ))
}

fn event_row(
  id: String,
  actor: String,
  timestamp_ns: Int,
  kind: String,
  time: workspace.TimeEstimate,
  evidence: workspace.Evidence,
) -> workspace.EventRow {
  workspace.EventRow(
    id: id,
    actor: actor,
    kind: kind,
    timestamp_ns: timestamp_ns,
    duration_ns: 0,
    time: time,
    evidence: evidence,
    anomalous: kind == "exit" || kind == "gap",
    internal: is_internal(actor),
  )
}

fn local_offset_decoder() -> decode.Decoder(Int) {
  use offset <- decode.field("offset_ns", decode.int)
  use _order <- decode.field("order", decode.int)
  decode.success(offset)
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

pub fn evidence_decoder() -> decode.Decoder(workspace.Evidence) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "exact" -> decode.success(workspace.Exact)
    "inferred" -> {
      use inference <- decode.field("inference", inference_decoder())
      decode.success(workspace.Inferred(inference.0, inference.1))
    }
    _ -> decode.failure(workspace.Exact, expected: "event evidence")
  }
}

fn inference_decoder() -> decode.Decoder(#(String, String)) {
  use method <- decode.field("method", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(#(method, reason))
}

fn legacy_evidence_decoder() -> decode.Decoder(workspace.Evidence) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "exact" -> decode.success(workspace.Exact)
    "inferred" -> {
      use reason <- decode.field("reason", decode.string)
      use _confidence <- decode.field("confidence", decode.float)
      decode.success(workspace.Inferred("legacy_v1_inference", reason))
    }
    _ -> decode.failure(workspace.Exact, expected: "legacy event evidence")
  }
}

pub fn time_estimate_decoder() -> decode.Decoder(workspace.TimeEstimate) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "exact" -> {
      use value <- decode.field("value_ns", decode.string)
      decode.success(workspace.ExactTime(value))
    }
    "estimated" -> {
      use value <- decode.field("value_ns", decode.string)
      use lower <- decode.field("lower_ns", decode.string)
      use upper <- decode.field("upper_ns", decode.string)
      decode.success(workspace.EstimatedTime(value, lower, upper))
    }
    "unavailable" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(workspace.TimeUnavailable(reason))
    }
    _ ->
      decode.failure(
        workspace.TimeUnavailable("invalid time estimate"),
        expected: "time estimate",
      )
  }
}

/// Convert a legacy safe integer for compatibility-only callers.
pub fn legacy_exact_time(value: Int) -> workspace.TimeEstimate {
  workspace.ExactTime(int.to_string(value))
}

fn is_internal(actor: String) -> Bool {
  let normalized = string.lowercase(actor)
  string.contains(normalized, "logger")
  || string.contains(normalized, "code_server")
  || string.contains(normalized, "beamtrace")
  || string.contains(normalized, "standard_io")
}
