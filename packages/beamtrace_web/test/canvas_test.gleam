// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/canvas
import beamtrace_web/workspace
import gleam/string
import gleeunit/should

fn row(id: String, internal: Bool) {
  workspace.EventRow(
    id: id,
    actor: case internal {
      True -> "logger"
      False -> "checkout"
    },
    kind: case internal {
      True -> "otp_internal"
      False -> "send"
    },
    timestamp_ns: 100,
    duration_ns: 10,
    evidence: workspace.Exact,
    anomalous: False,
    internal: internal,
  )
}

pub fn canvas_payload_contains_only_filtered_virtual_window_test() {
  let model = workspace.init([row("public", False), row("noise", True)])
  let payload = canvas.payload(model)

  payload |> string.contains("public") |> should.be_true()
  payload |> string.contains("noise") |> should.be_false()
  payload |> string.contains("checkout") |> should.be_true()
}

pub fn canvas_payload_never_contains_annotation_text_test() {
  let model = workspace.init([row("public", False)])
  let model =
    workspace.update(
      model,
      workspace.UserChangedAnnotation("SENTINEL-private-note"),
    )

  canvas.payload(model)
  |> string.contains("SENTINEL-private-note")
  |> should.be_false()
}
