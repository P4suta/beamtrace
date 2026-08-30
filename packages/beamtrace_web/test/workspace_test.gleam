import beamtrace_web/workspace
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn event(index: Int, internal: Bool) {
  workspace.EventRow(
    id: "event-" <> int.to_string(index),
    actor: case internal {
      True -> "logger"
      False -> "checkout"
    },
    kind: case internal {
      True -> "otp_internal"
      False -> "call"
    },
    timestamp_ns: index * 1000,
    duration_ns: 100,
    time: workspace.ExactTime(int.to_string(index * 1000)),
    evidence: workspace.Exact,
    anomalous: index == 42,
    internal: internal,
  )
}

fn events(count: Int) {
  int.range(from: 0, to: count, with: [], run: fn(rows, index) {
    [event(index, False), ..rows]
  })
  |> list.reverse
}

pub fn mode_switch_keeps_selection_and_query_test() {
  let model = workspace.init(events(4))
  let model = workspace.update(model, workspace.UserSelectedEvent("event-2"))
  let model = workspace.update(model, workspace.UserChangedQuery("mailbox"))
  let model =
    workspace.update(model, workspace.UserSelectedMode(workspace.Compare))

  model.mode |> should.equal(workspace.Compare)
  model.selected_event_id |> should.equal(Some("event-2"))
  model.query |> should.equal("mailbox")
}

pub fn canvas_window_never_materializes_all_events_test() {
  let model = workspace.init(events(1000))
  let model = workspace.update(model, workspace.ViewportChanged(500, 30))
  let visible = workspace.visible_events(model)

  visible |> list.length |> should.equal(30)
  visible |> list.first |> should.equal(Ok(event(500, False)))
}

pub fn internal_noise_is_folded_but_expandable_test() {
  let rows = [event(0, False), event(1, True), event(2, True), event(3, False)]
  let model = workspace.init(rows)
  workspace.filtered_events(model) |> list.length |> should.equal(2)

  model
  |> workspace.update(workspace.UserToggledInternalNoise)
  |> workspace.filtered_events
  |> list.length
  |> should.equal(4)
}

pub fn keyboard_shortcuts_cover_modes_search_and_palette_test() {
  workspace.keyboard_shortcut("1")
  |> should.equal(Some(workspace.UserSelectedMode(workspace.Capture)))
  workspace.keyboard_shortcut("2")
  |> should.equal(Some(workspace.UserSelectedMode(workspace.Live)))
  workspace.keyboard_shortcut("3")
  |> should.equal(Some(workspace.UserSelectedMode(workspace.Compare)))
  workspace.keyboard_shortcut("4")
  |> should.equal(Some(workspace.UserSelectedMode(workspace.Team)))
  workspace.keyboard_shortcut("/")
  |> should.equal(Some(workspace.UserFocusedSearch))
  workspace.keyboard_shortcut("k")
  |> should.equal(Some(workspace.UserOpenedPalette))
  workspace.keyboard_shortcut("x") |> should.equal(None)
}

pub fn team_trace_selection_never_loads_locked_contents_and_ignores_stale_pages_test() {
  let metadata =
    workspace.TeamTrace(
      "metadata-trace",
      "app@host",
      "shop",
      "checkout",
      1,
      "metadata",
      "delivered",
      10,
      1000,
      False,
      False,
    )
  let raw =
    workspace.TeamTrace(
      "raw-trace",
      "app@host",
      "shop",
      "raw",
      0,
      "raw",
      "partial",
      5,
      2000,
      True,
      True,
    )
  let model =
    workspace.init_remote()
    |> workspace.update(workspace.UserSelectedMode(workspace.Team))
    |> workspace.update(
      workspace.TeamTracesLoaded(workspace.TeamTracePage([metadata, raw], None)),
    )
    |> workspace.update(workspace.UserSelectedTeamTrace("raw-trace"))
  model.team_events_loading |> should.be_false()
  model.team_events_error
  |> should.equal(Some("Raw trace content is locked for this role"))

  let model =
    workspace.update(model, workspace.UserSelectedTeamTrace("metadata-trace"))
  model.team_events_loading |> should.be_true()
  let stale =
    workspace.update(
      model,
      workspace.TeamEventsLoaded(workspace.TeamEventPage(
        "raw-trace",
        [event(1, False)],
        None,
      )),
    )
  stale.team_events |> should.equal([])
  let loaded =
    workspace.update(
      stale,
      workspace.TeamEventsLoaded(workspace.TeamEventPage(
        "metadata-trace",
        [event(2, False)],
        Some("next"),
      )),
    )
  loaded.team_events |> should.equal([event(2, False)])
  loaded.team_events_next_cursor |> should.equal(Some("next"))
}

pub fn zoom_is_clamped_for_readability_test() {
  let model = workspace.init([])
  workspace.update(model, workspace.UserZoomed(100.0)).zoom |> should.equal(4.0)
  workspace.update(model, workspace.UserZoomed(0.01)).zoom |> should.equal(0.25)
}

pub fn bookmark_toggle_is_reversible_test() {
  let model = workspace.init([event(1, False)])
  let model = workspace.update(model, workspace.UserToggledBookmark("event-1"))
  model.bookmarks |> should.equal(["event-1"])

  workspace.update(model, workspace.UserToggledBookmark("event-1")).bookmarks
  |> should.equal([])
}

pub fn query_filters_by_actor_and_kind_without_losing_source_rows_test() {
  let rows = [event(1, False), event(2, True)]
  let model = workspace.init(rows)
  let model = workspace.update(model, workspace.UserToggledInternalNoise)
  let model = workspace.update(model, workspace.UserChangedQuery("LOGGER"))

  workspace.filtered_events(model) |> should.equal([event(2, True)])
  model.events |> should.equal(rows)
}

pub fn remote_page_replaces_the_window_and_preserves_global_count_test() {
  let page =
    workspace.EventPage(
      [event(500, False), event(501, False)],
      1_000_000,
      500,
      80,
    )
  let model =
    workspace.init_remote()
    |> workspace.update(workspace.PageLoaded("", page))
    |> workspace.update(workspace.ViewportChanged(500, 80))

  model.total_events |> should.equal(1_000_000)
  model.loaded_start |> should.equal(500)
  model.events |> list.length |> should.equal(2)
  workspace.visible_events(model)
  |> list.first
  |> should.equal(Ok(event(500, False)))
  workspace.needs_page(model) |> should.be_false()

  model
  |> workspace.update(workspace.ViewportChanged(900, 80))
  |> workspace.needs_page
  |> should.be_true()
}

pub fn remote_search_reloads_globally_and_ignores_stale_responses_test() {
  let initial_page = workspace.EventPage([event(1, False)], 100, 0, 200)
  let search_page = workspace.EventPage([event(42, False)], 1, 0, 200)
  let model =
    workspace.init_remote()
    |> workspace.update(workspace.PageLoaded("", initial_page))
    |> workspace.update(workspace.UserChangedQuery(" restart "))

  workspace.needs_page(model) |> should.be_true()
  workspace.remote_query(model) |> should.equal("restart")

  let loading = workspace.begin_loading(model)
  let stale = workspace.update(loading, workspace.PageLoaded("", initial_page))
  stale.events |> should.equal(initial_page.events)
  workspace.needs_page(stale) |> should.be_true()

  let searched =
    stale
    |> workspace.begin_loading
    |> workspace.update(workspace.PageLoaded("restart", search_page))
  searched.events |> should.equal(search_page.events)
  searched.total_events |> should.equal(1)
  workspace.needs_page(searched) |> should.be_false()
}

pub fn capture_controls_preserve_the_trigger_and_track_the_real_session_test() {
  let model =
    workspace.init_remote()
    |> workspace.update(workspace.UserChangedTrigger("shop:checkout/1"))
    |> workspace.update(workspace.UserChangedCaptureWhere("arg.0.tag == order"))
    |> workspace.update(workspace.UserChangedCapturePreset("gen-server"))
    |> workspace.update(workspace.UserChangedMaxRoots("3"))
    |> workspace.update(workspace.UserRequestedArm)

  model.trigger_input |> should.equal("shop:checkout/1")
  model.capture_where |> should.equal("arg.0.tag == order")
  model.capture_preset |> should.equal("gen-server")
  model.capture_max_roots |> should.equal("3")
  model.capture_phase |> should.equal(workspace.Arming)

  let armed = workspace.update(model, workspace.CaptureArmAccepted)
  armed.capture_phase |> should.equal(workspace.Armed)

  let ready =
    workspace.update(
      armed,
      workspace.CaptureStatusLoaded(workspace.Ready(
        12,
        "sealed after 250ms quiet period · delivery verified",
      )),
    )
  ready.capture_phase
  |> should.equal(workspace.Ready(
    12,
    "sealed after 250ms quiet period · delivery verified",
  ))
  ready.capture_notice |> should.equal("")
  ready.viewport_start |> should.equal(0)
}

pub fn capture_rejects_an_invalid_root_count_before_network_io_test() {
  let model =
    workspace.init_remote()
    |> workspace.update(workspace.UserChangedTrigger("shop:checkout/1"))
    |> workspace.update(workspace.UserChangedMaxRoots("0"))
    |> workspace.update(workspace.UserRequestedArm)

  model.capture_phase |> should.equal(workspace.Failed("invalid_root_budget"))
  model.capture_notice |> should.equal("Max roots must be between 1 and 1000")
}

pub fn mfa_suggestions_are_bounded_model_state_not_fake_static_entries_test() {
  let model =
    workspace.init_remote()
    |> workspace.update(
      workspace.MfaSuggestionsLoaded([
        "shop:checkout/1",
        "shop:checkout/2",
      ]),
    )
  model.mfa_suggestions
  |> should.equal(["shop:checkout/1", "shop:checkout/2"])

  model
  |> workspace.update(workspace.UserChangedTrigger(""))
  |> fn(model) { model.mfa_suggestions }
  |> should.equal([])
}

pub fn failed_or_cancelled_capture_is_never_presented_as_verified_test() {
  let model = workspace.init_remote()
  let occupied =
    model
    |> workspace.update(
      workspace.CaptureStatusLoaded(workspace.Failed("system_tracer_occupied")),
    )
  occupied.capture_phase
  |> should.equal(workspace.Failed("system_tracer_occupied"))
  occupied.capture_notice
  |> string.contains("Live")
  |> should.be_true()

  model
  |> workspace.update(workspace.UserRequestedCancel)
  |> fn(model) { model.capture_phase }
  |> should.equal(workspace.Cancelling)
}

pub fn live_snapshot_replaces_process_state_and_filters_without_touching_capture_test() {
  let capture_rows = [event(1, False)]
  let snapshot =
    workspace.LiveSnapshot(
      generation: 7,
      sampled_at_ms: 1234,
      rows: [live_row("<0.42.0>", "orders worker")],
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
      supervision: [
        workspace.TopologyEdge(
          "orders_sup",
          "<0.42.0>",
          workspace.Inferred("proc_lib_ancestor", "proc_lib ancestor metadata"),
        ),
      ],
      spawn: [],
      links: [
        workspace.TopologyEdge("<0.7.0>", "<0.42.0>", workspace.Exact),
      ],
    )
  let model =
    workspace.init(capture_rows)
    |> workspace.update(workspace.UserSelectedMode(workspace.Live))
    |> workspace.update(workspace.LiveLoaded(snapshot))
    |> workspace.update(workspace.UserChangedQuery("ORDERS"))

  model.events |> should.equal(capture_rows)
  model.live_generation |> should.equal(7)
  workspace.filtered_live_rows(model)
  |> should.equal([live_row("<0.42.0>", "orders worker")])
  workspace.live_findings_for(model, "<0.42.0>")
  |> list.length
  |> should.equal(1)

  model
  |> workspace.update(workspace.UserSelectedLiveProcess("<0.42.0>"))
  |> workspace.selected_live_process
  |> should.equal(Ok(live_row("<0.42.0>", "orders worker")))
}

fn live_row(pid: String, label: String) -> workspace.LiveRow {
  workspace.LiveRow(
    node: "app@host",
    pid: pid,
    label: label,
    registered_name: "orders",
    process_label: label,
    initial_call: "orders_worker:init/1",
    mailbox_len: 50,
    memory_bytes: 10_000,
    reductions: 1000,
    heap_words: 100,
    total_heap_words: 200,
    link_count: 1,
    status: "waiting",
    current_function: "gen_server:loop/7",
    links: ["<0.7.0>"],
    ancestors: ["orders_sup"],
  )
}

pub fn compare_requires_two_to_twenty_paths_and_preserves_capture_state_test() {
  let original = [event(1, False)]
  let invalid =
    workspace.init(original)
    |> workspace.update(workspace.UserSelectedMode(workspace.Compare))
    |> workspace.update(workspace.UserChangedComparePaths("only.beamtrace"))
    |> workspace.update(workspace.UserRequestedCompare)
  invalid.compare_error
  |> should.equal(Some("Enter 2–20 distinct .beamtrace paths"))

  let ready =
    invalid
    |> workspace.update(workspace.UserChangedComparePaths(
      "left.beamtrace\nslow.beamtrace\nmissing.beamtrace",
    ))
    |> workspace.update(workspace.UserRequestedCompare)
  ready.compare_loading |> should.be_true()
  workspace.compare_paths(ready)
  |> should.equal([
    "left.beamtrace",
    "slow.beamtrace",
    "missing.beamtrace",
  ])

  let report =
    workspace.CompareReport(
      "left.beamtrace",
      3,
      [workspace.CompareRun("slow.beamtrace", 1, 0, 0, 0, [], [])],
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
  let compared = workspace.update(ready, workspace.CompareLoaded(report))
  compared.events |> should.equal(original)
  compared.compare_report |> should.equal(Some(report))
  compared.compare_loading |> should.be_false()
}

pub fn theme_cycles_without_persistence_test() {
  let initial = workspace.init([])
  initial.theme |> should.equal(workspace.SystemTheme)
  let light = workspace.update(initial, workspace.UserCycledTheme)
  light.theme |> should.equal(workspace.LightTheme)
  let dark = workspace.update(light, workspace.UserCycledTheme)
  dark.theme |> should.equal(workspace.DarkTheme)
  workspace.update(dark, workspace.UserCycledTheme).theme
  |> should.equal(workspace.SystemTheme)
}

pub fn team_selects_two_to_twenty_traces_for_compare_test() {
  let traces = [team_trace("run-a"), team_trace("run-b"), team_trace("run-c")]
  let selected =
    workspace.init_remote()
    |> workspace.update(
      workspace.TeamTracesLoaded(workspace.TeamTracePage(traces, None)),
    )
    |> workspace.update(workspace.UserToggledTeamCompare("run-a"))
    |> workspace.update(workspace.UserToggledTeamCompare("run-b"))
    |> workspace.update(workspace.UserRequestedTeamCompare)

  selected.mode |> should.equal(workspace.Compare)
  selected.compare_loading |> should.be_true()
  workspace.compare_paths(selected)
  |> should.equal(["team:run-a", "team:run-b"])
}

fn team_trace(id: String) -> workspace.TeamTrace {
  workspace.TeamTrace(
    id,
    "app@host",
    "shop",
    "checkout",
    1,
    "metadata",
    "delivered",
    10,
    1000,
    False,
    False,
  )
}

pub fn escape_closes_the_command_palette_test() {
  let model = workspace.init(events(1))
  let opened = workspace.update(model, workspace.UserOpenedPalette)
  opened.palette_open |> should.be_true()
  let closed = workspace.update(opened, workspace.UserPressedKey("Escape"))
  closed.palette_open |> should.be_false()
  workspace.keyboard_shortcut("escape")
  |> should.equal(Some(workspace.UserClosedPalette))
}

pub fn sealed_status_on_first_load_hides_the_arming_form_test() {
  let sealed =
    workspace.init_remote()
    |> workspace.update(
      workspace.CaptureStatusLoaded(workspace.Ready(
        34,
        "sealed after 250ms quiet period · delivery verified",
      )),
    )
  sealed.capture_form_open |> should.be_false()
  let reopened = workspace.update(sealed, workspace.UserOpenedCaptureForm)
  reopened.capture_form_open |> should.be_true()

  let armed_here =
    workspace.init_remote()
    |> workspace.update(workspace.CaptureStatusLoaded(workspace.Idle))
    |> workspace.update(workspace.UserChangedTrigger("shop:checkout/1"))
    |> workspace.update(workspace.UserRequestedArm)
    |> workspace.update(workspace.CaptureStatusLoaded(workspace.Armed))
    |> workspace.update(
      workspace.CaptureStatusLoaded(workspace.Ready(1, "sealed")),
    )
  armed_here.capture_form_open |> should.be_true()
}
