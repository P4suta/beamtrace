// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/view
import beamtrace_web/workspace
import gleam/string
import gleeunit/should
import lustre/element

fn rendered_workspace() -> String {
  workspace.init([
    workspace.EventRow(
      id: "root-1",
      actor: "checkout",
      kind: "call",
      timestamp_ns: 1000,
      duration_ns: 800,
      evidence: workspace.Exact,
      anomalous: False,
      internal: False,
    ),
  ])
  |> view.workspace
  |> element.to_string
}

pub fn workspace_has_primary_regions_and_modes_test() {
  let html = rendered_workspace()
  html |> string.contains("BeamTrace") |> should.be_true()
  html |> string.contains("Capture") |> should.be_true()
  html |> string.contains("Live") |> should.be_true()
  html |> string.contains("Compare") |> should.be_true()
  html |> string.contains("Session navigator") |> should.be_true()
  html |> string.contains("Event inspector") |> should.be_true()
  html |> string.contains("Time minimap") |> should.be_true()
}

pub fn canvas_has_accessible_dom_equivalent_test() {
  let html = rendered_workspace()
  html |> string.contains("<canvas") |> should.be_true()
  html |> string.contains("aria-hidden=\"true\"") |> should.be_true()
  html |> string.contains("Accessible causal event table") |> should.be_true()
  html |> string.contains("<table") |> should.be_true()
  html |> string.contains("root-1") |> should.be_true()
}

pub fn workspace_exposes_keyboard_and_motion_accessibility_hints_test() {
  let html = rendered_workspace()
  html |> string.contains("aria-keyshortcuts=\"1\"") |> should.be_true()
  html |> string.contains("aria-keyshortcuts=\"/\"") |> should.be_true()
  html |> string.contains("aria-live=\"polite\"") |> should.be_true()
}
