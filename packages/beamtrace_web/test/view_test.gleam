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
      time: workspace.ExactTime("1000"),
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
      "app@host",
      "shop",
      "checkout",
      1,
      "raw",
      "partial",
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

pub fn capture_workspace_keeps_advanced_fields_disclosed_and_save_post_capture_test() {
  let html = rendered_workspace()
  html |> string.contains("aria-label=\"MFA trigger\"") |> should.be_true()
  html |> string.contains("aria-label=\"AQL condition\"") |> should.be_true()
  html |> string.contains("aria-label=\"Framework preset\"") |> should.be_true()
  html |> string.contains("aria-label=\"Max roots\"") |> should.be_true()
  html |> string.contains("Arm capture") |> should.be_true()
  html |> string.contains("Cancel capture") |> should.be_true()
  html |> string.contains("Advanced") |> should.be_true()
  html |> string.contains("Save capture") |> should.be_false()
  html |> string.contains("checkout@local") |> should.be_false()
  html |> string.contains("list=\"mfa-candidates\"") |> should.be_true()

  let ready =
    workspace.init([])
    |> workspace.update(
      workspace.CaptureStatusLoaded(workspace.Ready(
        1,
        "sealed after 250ms quiet period · delivery verified",
      )),
    )
    |> view.workspace
    |> element.to_string
  ready |> string.contains("Save capture") |> should.be_true()
  ready |> string.contains("Choose a save path") |> should.be_true()
}

pub fn workspace_has_bt_brand_theme_mobile_drawers_and_evidence_summary_test() {
  let html = rendered_workspace()
  html |> string.contains(">BT<") |> should.be_true()
  html |> string.contains("Theme · System") |> should.be_true()
  html |> string.contains("Mobile workspace mode") |> should.be_true()
  html |> string.contains("What this trace establishes") |> should.be_true()
  html |> string.contains("Delivery verification") |> should.be_true()
  html |> string.contains("Evidence basis") |> should.be_true()
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
          workspace.Inferred(
            "ewma_hysteresis",
            "EWMA exceeded baseline with hysteresis",
          ),
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
        workspace.CompareRun("slow.beamtrace", 1, 0, 0, 0, [], [
          workspace.CompareItem(
            "matched",
            "left-send",
            "right-send",
            workspace.ExactTime("90"),
            "",
          ),
        ]),
      ],
      [
        workspace.BranchStatistic(
          "orders|send:tag:work",
          workspace.TimeSummary(workspace.ExactTime("10"), 2, 0),
          workspace.TimeSummary(workspace.ExactTime("100"), 2, 0),
          2,
          3,
        ),
      ],
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
  html |> string.contains("+90 ns · exact") |> should.be_true()
  html |> string.contains("p95 +100 ns · exact") |> should.be_true()
  html |> string.contains("2/3 runs") |> should.be_true()
}

pub fn keyboard_targets_are_wired_for_every_advertised_shortcut_test() {
  let html = rendered_workspace()
  html |> string.contains("aria-keyshortcuts=\"4\"") |> should.be_true()
  html |> string.contains("id=\"event-search\"") |> should.be_true()
  let palette =
    workspace.init([])
    |> workspace.update(workspace.UserOpenedPalette)
    |> view.workspace
    |> element.to_string
  palette |> string.contains("autofocus") |> should.be_true()
  palette |> string.contains("Command palette") |> should.be_true()
}

pub fn sealed_landing_renders_overview_with_save_and_new_capture_test() {
  let html =
    workspace.init_remote()
    |> workspace.update(
      workspace.CaptureStatusLoaded(workspace.Ready(
        34,
        "sealed after 250ms quiet period · delivery verified",
      )),
    )
    |> view.workspace
    |> element.to_string
  html |> string.contains("Sealed archive") |> should.be_true()
  html |> string.contains("34 events") |> should.be_true()
  html |> string.contains("Save capture") |> should.be_true()
  html |> string.contains("New capture") |> should.be_true()
  html |> string.contains("Arm capture") |> should.be_false()
  html |> string.contains("Sealed causal observation") |> should.be_true()
  html |> string.contains("No trigger armed") |> should.be_false()
}

pub fn event_table_shows_an_actionable_empty_state_test() {
  let html = workspace.init([]) |> view.workspace |> element.to_string
  html |> string.contains("No events in this window") |> should.be_true()
  let searched =
    workspace.init([])
    |> workspace.update(workspace.UserChangedQuery("needle"))
    |> view.workspace
    |> element.to_string
  searched |> string.contains("No events match") |> should.be_true()
}

pub fn event_rows_render_human_time_and_keep_raw_values_in_the_inspector_test() {
  let model =
    workspace.init([
      workspace.EventRow(
        id: "event-1",
        actor: "checkout",
        kind: "send",
        timestamp_ns: 15_893_571,
        duration_ns: 1000,
        time: workspace.EstimatedTime(
          "1788090105011610338",
          "1788090105011580258",
          "1788090105011640420",
        ),
        evidence: workspace.Exact,
        anomalous: False,
        internal: False,
      ),
    ])
  let html = model |> view.workspace |> element.to_string
  html
  |> string.contains(
    "+15.894 ms · 2026-08-30 11:41:45.011610 UTC ±30.081 µs · estimated",
  )
  |> should.be_true()
  html |> string.contains("ns node-local") |> should.be_false()
  let inspector =
    model
    |> workspace.update(workspace.UserSelectedEvent("event-1"))
    |> view.workspace
    |> element.to_string
  inspector
  |> string.contains(
    "1788090105011610338 ns estimated [1788090105011580258, 1788090105011640420]",
  )
  |> should.be_true()
}
