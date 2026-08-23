// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic.{type Dynamic}
import gleam/json

/// The Canvas renderer receives only the currently visible metadata rows. User
/// annotations and any capture payload values never cross this FFI boundary.
pub fn payload(model: workspace.Model) -> String {
  model
  |> workspace.visible_events
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

@external(javascript, "./canvas_ffi.mjs", "draw")
pub fn draw(root: Dynamic, payload: String, zoom: Float) -> Nil

@external(javascript, "./canvas_ffi.mjs", "installShortcuts")
pub fn install_shortcuts(handler: fn(String) -> Nil) -> Nil
