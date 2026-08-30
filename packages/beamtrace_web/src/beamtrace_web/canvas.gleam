// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{None, Some}

/// Canvas receives only visible metadata plus actual API graph relationships.
/// Annotation and captured term payload values never cross the FFI boundary.
pub fn payload(model: workspace.Model) -> String {
  case model.mode {
    workspace.Live -> live_payload(model)
    workspace.Team -> rows_payload(model.team_events, [], [], [])
    _ ->
      rows_payload(
        workspace.visible_events(model),
        model.graph_edges,
        model.graph_boundaries,
        divergence_path(model),
      )
  }
}

fn rows_payload(
  rows: List(workspace.EventRow),
  edges: List(workspace.GraphEdge),
  boundaries: List(workspace.GraphBoundary),
  divergence: List(String),
) -> String {
  let rows = list.take(rows, 1000)
  let ids = list.map(rows, fn(row) { row.id })
  json.object([
    #("rows", json.array(rows, row_json)),
    #(
      "edges",
      edges
        |> list.filter(fn(edge) {
          list.contains(ids, edge.from) || list.contains(ids, edge.to)
        })
        |> json.array(edge_json),
    ),
    #(
      "boundaries",
      boundaries
        |> list.filter(fn(boundary) { list.contains(ids, boundary.event_id) })
        |> json.array(boundary_json),
    ),
    #("divergence_path", json.array(divergence, json.string)),
  ])
  |> json.to_string
}

fn row_json(row: workspace.EventRow) -> json.Json {
  json.object([
    #("id", json.string(row.id)),
    #("actor", json.string(row.actor)),
    #("kind", json.string(row.kind)),
    #("local_offset_ns", json.int(row.timestamp_ns)),
    #("duration_ns", json.int(row.duration_ns)),
    #("time", time_json(row.time)),
    #("anomalous", json.bool(row.anomalous)),
    #("evidence", json.string(evidence_kind(row.evidence))),
  ])
}

fn edge_json(edge: workspace.GraphEdge) -> json.Json {
  json.object([
    #("from", json.string(edge.from)),
    #("to", json.string(edge.to)),
    #("kind", json.string(edge.kind)),
    #("evidence", json.string(evidence_kind(edge.evidence))),
  ])
}

fn boundary_json(boundary: workspace.GraphBoundary) -> json.Json {
  json.object([
    #("event_id", json.string(boundary.event_id)),
    #("kind", json.string(boundary.kind)),
    #("reason", json.string(boundary.reason)),
  ])
}

fn time_json(time: workspace.TimeEstimate) -> json.Json {
  case time {
    workspace.ExactTime(value) ->
      json.object([
        #("kind", json.string("exact")),
        #("value_ns", json.string(value)),
      ])
    workspace.EstimatedTime(value, lower, upper) ->
      json.object([
        #("kind", json.string("estimated")),
        #("value_ns", json.string(value)),
        #("lower_ns", json.string(lower)),
        #("upper_ns", json.string(upper)),
      ])
    workspace.TimeUnavailable(reason) ->
      json.object([
        #("kind", json.string("unavailable")),
        #("reason", json.string(reason)),
      ])
  }
}

fn evidence_kind(evidence: workspace.Evidence) -> String {
  case evidence {
    workspace.Exact -> "exact"
    workspace.Inferred(_, _) -> "inferred"
  }
}

fn divergence_path(model: workspace.Model) -> List(String) {
  case model.compare_report {
    Some(report) -> first_divergence(report.reports)
    None -> []
  }
}

fn first_divergence(reports: List(workspace.CompareRun)) -> List(String) {
  case reports {
    [] -> []
    [run, ..rest] ->
      case run.first_divergence_path {
        [] -> first_divergence(rest)
        path -> path
      }
  }
}

fn live_payload(model: workspace.Model) -> String {
  let rows =
    model
    |> workspace.filtered_live_rows
    |> list.take(200)
    |> list.map(fn(row) {
      let anomalous =
        list.any(model.live_findings, fn(finding) { finding.pid == row.pid })
      workspace.EventRow(
        id: row.pid,
        actor: row.label,
        kind: row.status,
        timestamp_ns: row.reductions,
        duration_ns: row.mailbox_len,
        time: workspace.TimeUnavailable("live sample has no causal clock"),
        anomalous: anomalous,
        evidence: case anomalous {
          True -> workspace.Inferred("live_sampling", "diagnostic threshold")
          False -> workspace.Exact
        },
        internal: False,
      )
    })
  let supervision =
    list.map(model.live_supervision, fn(edge) {
      workspace.GraphEdge(edge.from, edge.to, "supervision", edge.evidence)
    })
  let spawn =
    list.map(model.live_spawn, fn(edge) {
      workspace.GraphEdge(edge.from, edge.to, "spawned", edge.evidence)
    })
  let links =
    list.map(model.live_links, fn(edge) {
      workspace.GraphEdge(
        edge.from,
        edge.to,
        "link_relationship",
        edge.evidence,
      )
    })
  rows_payload(
    rows,
    supervision |> list.append(spawn) |> list.append(links),
    [],
    [],
  )
}

@external(javascript, "./canvas_ffi.mjs", "draw")
pub fn draw(root: Dynamic, payload: String, zoom: Float) -> Nil

@external(javascript, "./canvas_ffi.mjs", "installShortcuts")
pub fn install_shortcuts(handler: fn(String) -> Nil) -> Nil

@external(javascript, "./canvas_ffi.mjs", "focusSearch")
pub fn focus_search() -> Nil

@external(javascript, "./canvas_ffi.mjs", "focusPalette")
pub fn focus_palette() -> Nil

@external(javascript, "./canvas_ffi.mjs", "restoreFocus")
pub fn restore_focus() -> Nil
