// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/diff
import beamtrace/stats
import beamtrace/types
import beamtrace_runtime/capture
import beamtrace_runtime/capture_session
import beamtrace_runtime/compare_workspace
import beamtrace_runtime/live
import beamtrace_runtime/rbac
import beamtrace_runtime/storage
import beamtrace_runtime/topology
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import wisp

/// Dependencies owned by the local workspace API. Authorization is supplied
/// by the outer router so this module does not depend on the public API facade.
pub type Context {
  Context(
    local_mode: Bool,
    tool_version: String,
    archive_path: Option(String),
    local_capture: Option(capture_session.Store),
    authorize: fn(rbac.Action) -> Bool,
  )
}

type CaptureArmPayload {
  CaptureArmPayload(
    trigger: String,
    where_aql: Option(String),
    capture_window_ms: Int,
    max_events: Int,
    max_bytes: Int,
    max_agent_mailbox: Int,
    max_roots: Int,
    preset: String,
  )
}

type CaptureSavePayload {
  CaptureSavePayload(path: String)
}

type ComparePayload {
  ComparePayload(paths: List(String))
}

pub fn compare_response(
  incoming: wisp.Request,
  context: Context,
  _now_ms: Int,
) -> wisp.Response {
  case context.local_mode {
    False -> wisp.not_found()
    True ->
      case context.authorize(rbac.ViewSession) {
        False -> wisp.response(401)
        True ->
          case decode_json_body(incoming, compare_payload_decoder()) {
            Error("too_large") -> wisp.response(413)
            Error(_) ->
              wisp.json_response("{\"error\":\"invalid_request\"}", 400)
            Ok(payload) ->
              case compare_workspace.compare(payload.paths) {
                Error(compare_workspace.InvalidPaths) ->
                  wisp.json_response("{\"error\":\"invalid_paths\"}", 400)
                Error(compare_workspace.LoadFailed(path, _)) ->
                  json.object([
                    #("error", json.string("trace_load_failed")),
                    #("path", json.string(path)),
                  ])
                  |> json.to_string
                  |> wisp.json_response(422)
                Ok(report) ->
                  report
                  |> compare_report_json
                  |> json.to_string
                  |> wisp.json_response(200)
              }
          }
      }
  }
}

fn compare_payload_decoder() -> decode.Decoder(ComparePayload) {
  use paths <- decode.field("paths", decode.list(decode.string))
  decode.success(ComparePayload(paths))
}

fn compare_report_json(report: compare_workspace.Report) -> json.Json {
  json.object([
    #("baseline", json.string(report.baseline)),
    #("run_count", json.int(report.run_count)),
    #("reports", json.array(report.reports, compare_run_json)),
    #("statistics", json.array(report.statistics, branch_stats_json)),
  ])
}

fn compare_run_json(report: compare_workspace.RunReport) -> json.Json {
  json.object([
    #("path", json.string(report.path)),
    #("added", json.int(report.added)),
    #("removed", json.int(report.removed)),
    #("changed", json.int(report.changed)),
    #("items", json.array(report.items, diff_item_json)),
  ])
}

fn diff_item_json(item: diff.DiffItem) -> json.Json {
  case item {
    diff.Matched(left_id, right_id, latency_delta_ns) ->
      json.object([
        #("status", json.string("matched")),
        #("left_id", json.string(left_id)),
        #("right_id", json.string(right_id)),
        #("latency_delta_ns", json.int(latency_delta_ns)),
      ])
    diff.Added(right_id) ->
      json.object([
        #("status", json.string("added")),
        #("right_id", json.string(right_id)),
      ])
    diff.Removed(left_id) ->
      json.object([
        #("status", json.string("removed")),
        #("left_id", json.string(left_id)),
      ])
    diff.Changed(left_id, right_id, reason) ->
      json.object([
        #("status", json.string("changed")),
        #("left_id", json.string(left_id)),
        #("right_id", json.string(right_id)),
        #("reason", json.string(reason)),
      ])
  }
}

fn branch_stats_json(statistic: stats.BranchStats) -> json.Json {
  json.object([
    #("signature", json.string(statistic.signature)),
    #("p50_ns", json.int(statistic.p50_ns)),
    #("p95_ns", json.int(statistic.p95_ns)),
    #("occurrences", json.int(statistic.occurrences)),
    #("total_runs", json.int(statistic.total_runs)),
    #("occurrence_rate", json.float(statistic.occurrence_rate)),
  ])
}

pub fn capture_status_response(
  _incoming: wisp.Request,
  context: Context,
  _now_ms: Int,
) -> wisp.Response {
  case context.authorize(rbac.ViewSession) {
    False -> wisp.response(401)
    True ->
      case context.local_capture {
        None -> wisp.not_found()
        Some(store) ->
          store
          |> capture_session.status
          |> capture_status_json
          |> wisp.json_response(200)
      }
  }
}

pub fn mfa_search_response(
  incoming: wisp.Request,
  context: Context,
  _now_ms: Int,
) -> wisp.Response {
  case context.authorize(rbac.ViewSession) {
    False -> wisp.response(401)
    True ->
      case context.local_capture {
        None -> wisp.not_found()
        Some(store) ->
          case mfa_search_parameters(incoming, capture_session.nodes(store)) {
            Error(reason) ->
              json.object([#("error", json.string(reason))])
              |> json.to_string
              |> wisp.json_response(400)
            Ok(#(node, query, limit)) ->
              case capture_session.search_mfas(store, node, query, limit) {
                Ok(candidates) ->
                  json.object([
                    #("candidates", json.array(candidates, mfa_candidate_json)),
                  ])
                  |> json.to_string
                  |> wisp.json_response(200)
                Error(capture_session.InvalidSessionRequest(reason)) ->
                  json.object([#("error", json.string(reason))])
                  |> json.to_string
                  |> wisp.json_response(400)
                Error(_) ->
                  wisp.json_response("{\"error\":\"mfa_search_failed\"}", 422)
              }
          }
      }
  }
}

pub fn live_snapshot_response(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  case context.authorize(rbac.ViewSession) {
    False -> wisp.response(401)
    True ->
      case context.local_capture {
        None -> wisp.not_found()
        Some(store) ->
          case live_parameters(incoming, capture_session.nodes(store)) {
            Error(reason) ->
              json.object([#("error", json.string(reason))])
              |> json.to_string
              |> wisp.json_response(400)
            Ok(#(node, limit)) ->
              case
                capture_session.live_snapshot_at(
                  store,
                  node,
                  limit,
                  now_ms,
                  500,
                )
              {
                Ok(snapshot) -> live_snapshot_json(node, snapshot)
                Error(capture_session.InvalidSessionRequest(reason)) ->
                  json.object([#("error", json.string(reason))])
                  |> json.to_string
                  |> wisp.json_response(400)
                Error(_) ->
                  wisp.json_response(
                    "{\"error\":\"live_sampling_failed\"}",
                    422,
                  )
              }
          }
      }
  }
}

fn live_parameters(
  incoming: wisp.Request,
  nodes: List(String),
) -> Result(#(String, Int), String) {
  case request.get_query(incoming) {
    Error(_) -> Error("invalid_query")
    Ok(query) -> {
      let node = case list.key_find(query, "node") {
        Ok(value) -> value
        Error(_) ->
          case nodes {
            [first, ..] -> first
            [] -> ""
          }
      }
      case int.parse(query_value(query, "limit", "200")) {
        Ok(limit) if node != "" && limit > 0 && limit <= 1000 ->
          Ok(#(node, limit))
        _ -> Error("invalid_live_sample")
      }
    }
  }
}

fn live_snapshot_json(
  node: String,
  snapshot: capture_session.LiveSnapshot,
) -> wisp.Response {
  let findings = live.analyze(snapshot.previous, snapshot.samples)
  let graphs = live.topology_graphs(snapshot.samples)
  json.object([
    #("node", json.string(node)),
    #("generation", json.int(snapshot.generation)),
    #("sampled_at_ms", json.int(snapshot.sampled_at_ms)),
    #("next_offset", json.int(snapshot.next_offset)),
    #("samples", json.array(snapshot.samples, live_sample_json)),
    #("findings", json.array(findings, live_finding_json)),
    #("topology", topology_json(graphs)),
  ])
  |> json.to_string
  |> wisp.json_response(200)
}

fn live_sample_json(sample: live.ProcessSample) -> json.Json {
  json.object([
    #("node", json.string(sample.node)),
    #("pid", json.string(sample.pid)),
    #("label", json.string(sample.label)),
    #("registered_name", json.string(sample.registered_name)),
    #("process_label", json.string(sample.process_label)),
    #("initial_call", json.string(sample.initial_call)),
    #("mailbox_len", json.int(sample.mailbox_len)),
    #("memory_bytes", json.int(sample.memory_bytes)),
    #("reductions", json.int(sample.reductions)),
    #("heap_words", json.int(sample.heap_words)),
    #("total_heap_words", json.int(sample.total_heap_words)),
    #("link_count", json.int(sample.link_count)),
    #("status", json.string(sample.status)),
    #("current_function", json.string(sample.current_function)),
    #("links", json.array(sample.links, json.string)),
    #("ancestors", json.array(sample.ancestors, json.string)),
  ])
}

fn live_finding_json(finding: live.LiveFinding) -> json.Json {
  json.object([
    #("pid", json.string(finding.pid)),
    #("label", json.string(finding.label)),
    #("kind", json.string(finding.kind)),
    #("summary", json.string(finding.summary)),
    #("evidence", evidence_json(finding.evidence)),
  ])
}

fn topology_json(graphs: topology.Graphs) -> json.Json {
  json.object([
    #("supervision", json.array(graphs.supervision, topology_edge_json)),
    #("spawn", json.array(graphs.spawn, topology_edge_json)),
    #("links", json.array(graphs.links, topology_edge_json)),
  ])
}

fn topology_edge_json(edge: topology.Edge) -> json.Json {
  json.object([
    #("from", json.string(edge.from)),
    #("to", json.string(edge.to)),
    #("evidence", evidence_json(edge.evidence)),
  ])
}

fn evidence_json(evidence: types.Evidence) -> json.Json {
  case evidence {
    types.Exact -> json.object([#("status", json.string("exact"))])
    types.Inferred(reason, confidence) ->
      json.object([
        #("status", json.string("inferred")),
        #("reason", json.string(reason)),
        #("confidence", json.float(confidence)),
      ])
  }
}

fn mfa_search_parameters(
  incoming: wisp.Request,
  nodes: List(String),
) -> Result(#(String, String, Int), String) {
  case request.get_query(incoming) {
    Error(_) -> Error("invalid_query")
    Ok(query) -> {
      let node = case list.key_find(query, "node") {
        Ok(value) -> value
        Error(_) ->
          case nodes {
            [first, ..] -> first
            [] -> ""
          }
      }
      let source = query_value(query, "q", "")
      let source_size = string.byte_size(source)
      case int.parse(query_value(query, "limit", "20")) {
        Ok(limit)
          if node != "" && source_size <= 256 && limit > 0 && limit <= 200
        -> Ok(#(node, source, limit))
        _ -> Error("invalid_mfa_search")
      }
    }
  }
}

fn mfa_candidate_json(candidate: capture.MfaCandidate) -> json.Json {
  json.object([
    #("node", json.string(candidate.node)),
    #("module", json.string(candidate.module_)),
    #("function", json.string(candidate.function_)),
    #("arity", json.int(candidate.arity)),
    #(
      "mfa",
      json.string(
        candidate.module_
        <> ":"
        <> candidate.function_
        <> "/"
        <> int.to_string(candidate.arity),
      ),
    ),
  ])
}

pub fn capture_arm_response(
  incoming: wisp.Request,
  context: Context,
  _now_ms: Int,
) -> wisp.Response {
  case context.authorize(rbac.StartMetadataCapture) {
    False -> wisp.response(401)
    True ->
      case context.local_capture {
        None -> wisp.not_found()
        Some(store) ->
          case decode_json_body(incoming, capture_arm_payload_decoder()) {
            Error("too_large") -> wisp.response(413)
            Error(_) ->
              wisp.json_response("{\"error\":\"invalid_request\"}", 400)
            Ok(payload) ->
              case
                parse_capture_mfa(payload.trigger),
                parse_capture_preset(payload.preset)
              {
                Error(_), _ ->
                  wisp.json_response("{\"error\":\"invalid_trigger\"}", 400)
                _, Error(_) ->
                  wisp.json_response("{\"error\":\"invalid_preset\"}", 400)
                Ok(trigger), Ok(preset) -> {
                  let spec =
                    capture_session.ArmSpec(
                      trigger: trigger,
                      where_aql: payload.where_aql,
                      capture_window_ms: payload.capture_window_ms,
                      budget: capture.Budget(
                        payload.max_events,
                        payload.max_bytes,
                        payload.max_agent_mailbox,
                      ),
                      max_roots: payload.max_roots,
                      preset: preset,
                    )
                  case capture_session.arm(store, spec) {
                    Ok(Nil) -> wisp.json_response("{\"status\":\"armed\"}", 202)
                    Error(capture_session.CaptureAlreadyRunning) ->
                      wisp.json_response(
                        "{\"error\":\"capture_already_running\"}",
                        409,
                      )
                    Error(capture_session.InvalidSessionRequest(reason)) ->
                      json.object([#("error", json.string(reason))])
                      |> json.to_string
                      |> wisp.json_response(400)
                    Error(_) ->
                      wisp.json_response("{\"error\":\"capture_failed\"}", 422)
                  }
                }
              }
          }
      }
  }
}

pub fn capture_cancel_response(
  _incoming: wisp.Request,
  context: Context,
  _now_ms: Int,
) -> wisp.Response {
  case context.authorize(rbac.StartMetadataCapture) {
    False -> wisp.response(401)
    True ->
      case context.local_capture {
        None -> wisp.not_found()
        Some(store) ->
          case capture_session.cancel(store) {
            Ok(Nil) -> wisp.json_response("{\"status\":\"cancelling\"}", 202)
            Error(_) ->
              wisp.json_response("{\"error\":\"capture_cancel_failed\"}", 409)
          }
      }
  }
}

pub fn capture_save_response(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  case context.authorize(rbac.StartMetadataCapture) {
    False -> wisp.response(401)
    True ->
      case context.local_capture {
        None -> wisp.not_found()
        Some(store) ->
          case decode_json_body(incoming, capture_save_payload_decoder()) {
            Error("too_large") -> wisp.response(413)
            Error(_) ->
              wisp.json_response("{\"error\":\"invalid_request\"}", 400)
            Ok(payload) ->
              save_capture(store, payload.path, context.tool_version, now_ms)
          }
      }
  }
}

fn save_capture(
  store: capture_session.Store,
  path: String,
  tool_version: String,
  now_ms: Int,
) -> wisp.Response {
  case
    path != "",
    string.byte_size(path) <= 4096,
    string.ends_with(string.lowercase(path), ".beamtrace")
  {
    False, _, _ | _, False, _ | _, _, False ->
      wisp.json_response("{\"error\":\"invalid_path\"}", 400)
    True, True, True ->
      case capture_session.result(store) {
        Error(capture_session.CaptureNotReady) ->
          wisp.json_response("{\"error\":\"capture_not_ready\"}", 409)
        Error(_) -> wisp.json_response("{\"error\":\"capture_failed\"}", 422)
        Ok(captured) -> {
          let manifest =
            codec.Manifest(
              schema_version: codec.schema_version,
              tool_version: tool_version,
              capture_id: "capture-" <> int.to_string(now_ms),
              nodes: capture_session.nodes(store),
              completeness: captured.completeness,
              privacy: types.Metadata,
              checksums: [],
            )
          case storage.save(path, manifest, captured.events) {
            Ok(Nil) ->
              json.object([
                #("status", json.string("saved")),
                #("path", json.string(path)),
              ])
              |> json.to_string
              |> wisp.json_response(201)
            Error(_) -> wisp.json_response("{\"error\":\"save_failed\"}", 422)
          }
        }
      }
  }
}

fn capture_status_json(status: capture_session.Status) -> String {
  let fields = case status {
    capture_session.Idle -> [#("status", json.string("idle"))]
    capture_session.Armed -> [#("status", json.string("armed"))]
    capture_session.Cancelling -> [#("status", json.string("cancelling"))]
    capture_session.Ready(event_count, completeness) -> [
      #("status", json.string("ready")),
      #("event_count", json.int(event_count)),
      #("completeness", json.string(completeness)),
    ]
    capture_session.Failed(reason) -> [
      #("status", json.string("failed")),
      #("reason", json.string(reason)),
      #("exact_capture", json.bool(reason != "system_tracer_occupied")),
      #(
        "fallback",
        json.string(case reason {
          "system_tracer_occupied" -> "live_sampling"
          _ -> "none"
        }),
      ),
    ]
  }
  json.object(fields) |> json.to_string
}

fn capture_arm_payload_decoder() -> decode.Decoder(CaptureArmPayload) {
  use trigger <- decode.field("trigger", decode.string)
  use where_aql <- decode.field("where", decode.optional(decode.string))
  use capture_window_ms <- decode.field("capture_window_ms", decode.int)
  use max_events <- decode.field("max_events", decode.int)
  use max_bytes <- decode.field("max_bytes", decode.int)
  use max_agent_mailbox <- decode.field("max_agent_mailbox", decode.int)
  use max_roots <- decode.optional_field("max_roots", 1, decode.int)
  use preset <- decode.optional_field("preset", "generic", decode.string)
  decode.success(CaptureArmPayload(
    trigger,
    where_aql,
    capture_window_ms,
    max_events,
    max_bytes,
    max_agent_mailbox,
    max_roots,
    preset,
  ))
}

fn capture_save_payload_decoder() -> decode.Decoder(CaptureSavePayload) {
  use path <- decode.field("path", decode.string)
  decode.success(CaptureSavePayload(path))
}

fn decode_json_body(
  incoming: wisp.Request,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  case wisp.read_body_bits(incoming) {
    Error(_) -> Error("too_large")
    Ok(body) ->
      case bit_array.byte_size(body) > 16_384, bit_array.to_string(body) {
        True, _ -> Error("too_large")
        _, Error(_) -> Error("invalid_utf8")
        False, Ok(source) ->
          case json.parse(source, decoder) {
            Ok(value) -> Ok(value)
            Error(_) -> Error("invalid_json")
          }
      }
  }
}

fn parse_capture_mfa(source: String) -> Result(types.Mfa, Nil) {
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

fn parse_capture_preset(source: String) -> Result(types.Preset, Nil) {
  case string.lowercase(source) {
    "generic" -> Ok(types.Generic)
    "gleam-actor" -> Ok(types.GleamActor)
    "gleam_actor" -> Ok(types.GleamActor)
    "wisp-mist" -> Ok(types.WispMist)
    "wisp_mist" -> Ok(types.WispMist)
    "gen-server" -> Ok(types.GenServer)
    "gen_server" -> Ok(types.GenServer)
    "phoenix" -> Ok(types.Phoenix)
    "erlang-supervisor" -> Ok(types.ErlangSupervisor)
    "erlang_supervisor" -> Ok(types.ErlangSupervisor)
    _ -> Error(Nil)
  }
}

pub fn event_window_response(
  incoming: wisp.Request,
  context: Context,
  _now_ms: Int,
) -> wisp.Response {
  case context.authorize(rbac.ViewSession) {
    False -> wisp.response(401)
    True ->
      case
        context.archive_path,
        pagination(incoming),
        event_search_query(incoming)
      {
        None, Ok(page), Ok(search_query) ->
          case context.local_capture {
            None -> wisp.not_found()
            Some(store) ->
              capture_session_event_window(store, page, search_query)
          }
        _, Error(_), _ ->
          wisp.json_response("{\"error\":\"invalid_window\"}", 400)
        _, _, Error(_) ->
          wisp.json_response("{\"error\":\"invalid_search\"}", 400)
        Some(path), Ok(page), Ok(search_query) -> {
          let #(start, limit) = page
          let result = case search_query {
            None -> storage.window(path, start:, limit:)
            Some(query) -> storage.search(path, query, start:, limit:)
          }
          case result {
            Ok(window) -> {
              let events =
                window.events
                |> list.map(codec.encode_event)
                |> string.join(",")
              wisp.json_response(
                "{\"start\":"
                  <> int.to_string(window.start)
                  <> ",\"limit\":"
                  <> int.to_string(window.limit)
                  <> ",\"total\":"
                  <> int.to_string(window.total)
                  <> ",\"events\":["
                  <> events
                  <> "]}",
                200,
              )
            }
            Error(storage.InvalidWindow) ->
              wisp.json_response("{\"error\":\"invalid_window\"}", 400)
            Error(storage.InvalidSearch) ->
              wisp.json_response("{\"error\":\"invalid_search\"}", 400)
            Error(_) ->
              wisp.json_response("{\"error\":\"invalid_archive\"}", 422)
          }
        }
      }
  }
}

fn capture_session_event_window(
  store: capture_session.Store,
  page: #(Int, Int),
  search_query: Option(String),
) -> wisp.Response {
  case capture_session.result(store) {
    Error(capture_session.CaptureNotReady) ->
      wisp.json_response("{\"error\":\"capture_not_ready\"}", 409)
    Error(_) -> wisp.json_response("{\"error\":\"capture_failed\"}", 422)
    Ok(captured) -> {
      let #(start, limit) = page
      let filtered = case search_query {
        None -> captured.events
        Some(query) -> {
          let needle = string.lowercase(query)
          list.filter(captured.events, fn(event) {
            event
            |> codec.encode_event
            |> string.lowercase
            |> string.contains(needle)
          })
        }
      }
      let total = list.length(filtered)
      case start <= total {
        False -> wisp.json_response("{\"error\":\"invalid_window\"}", 400)
        True ->
          filtered
          |> list.drop(start)
          |> list.take(limit)
          |> event_page_json(start, limit, total)
          |> wisp.json_response(200)
      }
    }
  }
}

fn event_page_json(
  events: List(types.TraceEvent),
  start: Int,
  limit: Int,
  total: Int,
) -> String {
  let encoded = events |> list.map(codec.encode_event) |> string.join(",")
  "{\"start\":"
  <> int.to_string(start)
  <> ",\"limit\":"
  <> int.to_string(limit)
  <> ",\"total\":"
  <> int.to_string(total)
  <> ",\"events\":["
  <> encoded
  <> "]}"
}

fn event_search_query(incoming: wisp.Request) -> Result(Option(String), Nil) {
  case request.get_query(incoming) {
    Error(_) -> Error(Nil)
    Ok(query) ->
      case list.key_find(query, "q") {
        Error(_) -> Ok(None)
        Ok(source) -> {
          let normalized = string.trim(source)
          case normalized == "", string.byte_size(normalized) <= 256 {
            True, _ -> Ok(None)
            False, True -> Ok(Some(normalized))
            False, False -> Error(Nil)
          }
        }
      }
  }
}

fn pagination(incoming: wisp.Request) -> Result(#(Int, Int), Nil) {
  case request.get_query(incoming) {
    Error(_) -> Error(Nil)
    Ok(query) ->
      case
        int.parse(query_value(query, "start", "0")),
        int.parse(query_value(query, "limit", "200"))
      {
        Ok(start), Ok(limit) -> Ok(#(start, limit))
        _, _ -> Error(Nil)
      }
  }
}

fn query_value(
  query: List(#(String, String)),
  key: String,
  default: String,
) -> String {
  case list.key_find(query, key) {
    Ok(value) -> value
    Error(_) -> default
  }
}
