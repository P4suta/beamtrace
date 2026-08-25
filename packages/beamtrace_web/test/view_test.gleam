// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/view
import beamtrace_web/workspace
import gleam/option.{None}
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
  html |> string.contains("Team traces") |> should.be_true()
  html |> string.contains("Session navigator") |> should.be_true()
  html |> string.contains("Event inspector") |> should.be_true()
  html |> string.contains("Time minimap") |> should.be_true()
}

pub fn team_workspace_renders_trace_policy_locks_and_admin_hold_action_test() {
  let trace =
    workspace.TeamTrace(
      "trace-raw",
      "incomplete",
      "app@host",
      "shop",
      "checkout",
      1,
      "raw",
      "incomplete",
      12,
      1000,
      False,
      True,
    )
  let html =
    workspace.init_remote()
    |> workspace.update(workspace.UserSelectedMode(workspace.Team))
    |> workspace.update(
      workspace.TeamTracesLoaded(workspace.TeamTracePage([trace], None)),
    )
    |> workspace.update(workspace.UserSelectedTeamTrace(trace.id))
    |> view.workspace
    |> element.to_string

  html |> string.contains("aria-label=\"Team traces\"") |> should.be_true()
  html |> string.contains("trace-raw") |> should.be_true()
  html |> string.contains("Content locked") |> should.be_true()
  html |> string.contains("Trace contents locked") |> should.be_true()
  html |> string.contains("Place legal hold") |> should.be_true()
  html |> string.contains("Admin role") |> should.be_true()
  html |> string.contains("event-team-secret") |> should.be_false()
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

pub fn capture_workspace_has_real_arm_cancel_and_save_controls_test() {
  let html = rendered_workspace()
  html |> string.contains("aria-label=\"MFA trigger\"") |> should.be_true()
  html |> string.contains("aria-label=\"AQL condition\"") |> should.be_true()
  html |> string.contains("aria-label=\"Framework preset\"") |> should.be_true()
  html |> string.contains("aria-label=\"Max roots\"") |> should.be_true()
  html |> string.contains("Arm capture") |> should.be_true()
  html |> string.contains("Cancel capture") |> should.be_true()
  html |> string.contains("Save capture") |> should.be_true()
  html |> string.contains("checkout@local") |> should.be_false()
  html |> string.contains("list=\"mfa-candidates\"") |> should.be_true()
}

pub fn capture_workspace_renders_only_candidates_returned_by_the_target_test() {
  let html =
    workspace.init([])
    |> workspace.update(
      workspace.MfaSuggestionsLoaded([
        "shop:checkout/1",
      ]),
    )
    |> view.workspace
    |> element.to_string
  html |> string.contains("value=\"shop:checkout/1\"") |> should.be_true()
  html |> string.contains("fake:trigger/0") |> should.be_false()
}

pub fn live_workspace_has_real_accessible_process_data_and_no_fake_lanes_test() {
  let snapshot =
    workspace.LiveSnapshot(
      generation: 2,
      sampled_at_ms: 1603,
      rows: [
        workspace.LiveRow(
          "app@host",
          "<0.42.0>",
          "orders worker",
          "orders",
          "orders worker",
          "orders_worker:init/1",
          50,
          10_000,
          1000,
          100,
          200,
          1,
          "waiting",
          "gen_server:loop/7",
          ["<0.7.0>"],
          ["orders_sup"],
        ),
      ],
      findings: [
        workspace.LiveFinding(
          "<0.42.0>",
          "orders worker",
          "mailbox_growth",
          "mailbox is growing above its baseline",
          workspace.Inferred("EWMA exceeded baseline with hysteresis", 0.8),
        ),
      ],
      supervision: [],
      spawn: [],
      links: [],
    )
  let html =
    workspace.init([])
    |> workspace.update(workspace.UserSelectedMode(workspace.Live))
    |> workspace.update(workspace.LiveLoaded(snapshot))
    |> view.workspace
    |> element.to_string

  html |> string.contains("Accessible live process table") |> should.be_true()
  html |> string.contains("orders worker") |> should.be_true()
  html |> string.contains("mailbox_growth") |> should.be_true()
  html |> string.contains("Generation 2") |> should.be_true()
  html |> string.contains("cart_server") |> should.be_false()
  html |> string.contains("vscode://") |> should.be_false()
}

pub fn compare_workspace_renders_paths_alignment_and_percentiles_test() {
  let report =
    workspace.CompareReport(
      "left.beamtrace",
      3,
      [
        workspace.CompareRun("slow.beamtrace", 1, 0, 0, [
          workspace.CompareItem("matched", "left-send", "right-send", 90, ""),
        ]),
      ],
      [workspace.BranchStatistic("orders|send:tag:work", 10, 100, 2, 3, 0.66)],
    )
  let html =
    workspace.init([])
    |> workspace.update(workspace.UserSelectedMode(workspace.Compare))
    |> workspace.update(workspace.CompareLoaded(report))
    |> view.workspace
    |> element.to_string

  html |> string.contains("aria-label=\"Trace paths\"") |> should.be_true()
  html |> string.contains("Run comparison") |> should.be_true()
  html
  |> string.contains("Accessible trace alignment table")
  |> should.be_true()
  html |> string.contains("slow.beamtrace") |> should.be_true()
  html |> string.contains("+90 ns") |> should.be_true()
  html |> string.contains("p95 100 ns") |> should.be_true()
  html |> string.contains("2/3 runs") |> should.be_true()
}
