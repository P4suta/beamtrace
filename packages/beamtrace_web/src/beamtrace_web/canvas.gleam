// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list

/// The Canvas renderer receives only the currently visible metadata rows. User
/// annotations and any capture payload values never cross this FFI boundary.
pub fn payload(model: workspace.Model) -> String {
  case model.mode {
    workspace.Live -> live_payload(model)
    workspace.Team -> rows_payload(model.team_events)
    _ -> event_payload(model)
  }
}

fn event_payload(model: workspace.Model) -> String {
  rows_payload(workspace.visible_events(model))
}

fn rows_payload(rows: List(workspace.EventRow)) -> String {
  rows
  |> list.take(1000)
  |> json.array(fn(row) {
    json.object([
      #("id", json.string(row.id)),
      #("actor", json.string(row.actor)),
      #("kind", json.string(row.kind)),
      #("timestamp_ns", json.int(row.timestamp_ns)),
      #("duration_ns", json.int(row.duration_ns)),
      #("anomalous", json.bool(row.anomalous)),
      #(
        "evidence",
        json.string(case row.evidence {
          workspace.Exact -> "exact"
          workspace.Inferred(_, _) -> "inferred"
        }),
      ),
    ])
  })
  |> json.to_string
}

fn live_payload(model: workspace.Model) -> String {
  model
  |> workspace.filtered_live_rows
  |> list.take(200)
  |> json.array(fn(row) {
    let anomalous =
      list.any(model.live_findings, fn(finding) { finding.pid == row.pid })
    json.object([
      #("id", json.string(row.pid)),
      #("actor", json.string(row.label)),
      #("kind", json.string(row.status)),
      #("timestamp_ns", json.int(row.reductions)),
      #("duration_ns", json.int(row.mailbox_len)),
      #("anomalous", json.bool(anomalous)),
      #(
        "evidence",
        json.string(case anomalous {
          True -> "inferred"
          False -> "exact"
        }),
      ),
    ])
  })
  |> json.to_string
}

@external(javascript, "./canvas_ffi.mjs", "draw")
pub fn draw(root: Dynamic, payload: String, zoom: Float) -> Nil

@external(javascript, "./canvas_ffi.mjs", "installShortcuts")
pub fn install_shortcuts(handler: fn(String) -> Nil) -> Nil
