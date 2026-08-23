import beamtrace_web/workspace
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
  workspace.keyboard_shortcut("/")
  |> should.equal(Some(workspace.UserFocusedSearch))
  workspace.keyboard_shortcut("k")
  |> should.equal(Some(workspace.UserOpenedPalette))
  workspace.keyboard_shortcut("x") |> should.equal(None)
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
