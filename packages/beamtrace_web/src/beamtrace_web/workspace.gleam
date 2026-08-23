// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Mode {
  Capture
  Live
  Compare
}

pub type Evidence {
  Exact
  Inferred(reason: String, confidence: Float)
}

pub type CapturePhase {
  Unavailable
  Idle
  Arming
  Armed
  Cancelling
  Ready(event_count: Int, completeness: String)
  Failed(reason: String)
}

pub type EventRow {
  EventRow(
    id: String,
    actor: String,
    kind: String,
    timestamp_ns: Int,
    duration_ns: Int,
    evidence: Evidence,
    anomalous: Bool,
    internal: Bool,
  )
}

pub type EventPage {
  EventPage(events: List(EventRow), total: Int, start: Int, limit: Int)
}

pub type LiveRow {
  LiveRow(
    node: String,
    pid: String,
    label: String,
    registered_name: String,
    process_label: String,
    initial_call: String,
    mailbox_len: Int,
    memory_bytes: Int,
    reductions: Int,
    heap_words: Int,
    total_heap_words: Int,
    link_count: Int,
    status: String,
    current_function: String,
    links: List(String),
    ancestors: List(String),
  )
}

pub type LiveFinding {
  LiveFinding(
    pid: String,
    label: String,
    kind: String,
    summary: String,
    evidence: Evidence,
  )
}

pub type TopologyEdge {
  TopologyEdge(from: String, to: String, evidence: Evidence)
}

pub type LiveSnapshot {
  LiveSnapshot(
    generation: Int,
    sampled_at_ms: Int,
    rows: List(LiveRow),
    findings: List(LiveFinding),
    supervision: List(TopologyEdge),
    spawn: List(TopologyEdge),
    links: List(TopologyEdge),
  )
}

pub type CompareItem {
  CompareItem(
    status: String,
    left_id: String,
    right_id: String,
    latency_delta_ns: Int,
    reason: String,
  )
}

pub type CompareRun {
  CompareRun(
    path: String,
    added: Int,
    removed: Int,
    changed: Int,
    items: List(CompareItem),
  )
}

pub type BranchStatistic {
  BranchStatistic(
    signature: String,
    p50_ns: Int,
    p95_ns: Int,
    occurrences: Int,
    total_runs: Int,
    occurrence_rate: Float,
  )
}

pub type CompareReport {
  CompareReport(
    baseline: String,
    run_count: Int,
    reports: List(CompareRun),
    statistics: List(BranchStatistic),
  )
}

pub type Model {
  Model(
    remote: Bool,
    mode: Mode,
    events: List(EventRow),
    total_events: Int,
    loaded_start: Int,
    loaded_limit: Int,
    loaded_query: String,
    loading: Bool,
    load_error: Option(String),
    selected_event_id: Option(String),
    query: String,
    show_internal: Bool,
    viewport_start: Int,
    viewport_size: Int,
    zoom: Float,
    palette_open: Bool,
    search_focused: Bool,
    bookmarks: List(String),
    annotation: String,
    trigger_input: String,
    mfa_suggestions: List(String),
    capture_where: String,
    capture_preset: String,
    capture_max_roots: String,
    save_path: String,
    capture_phase: CapturePhase,
    capture_notice: String,
    live_rows: List(LiveRow),
    live_findings: List(LiveFinding),
    live_supervision: List(TopologyEdge),
    live_spawn: List(TopologyEdge),
    live_links: List(TopologyEdge),
    live_generation: Int,
    live_sampled_at_ms: Int,
    live_loading: Bool,
    live_error: Option(String),
    selected_live_pid: Option(String),
    compare_paths_input: String,
    compare_loading: Bool,
    compare_error: Option(String),
    compare_report: Option(CompareReport),
  )
}

pub type Msg {
  UserSelectedMode(Mode)
  UserSelectedEvent(String)
  UserChangedQuery(String)
  UserToggledInternalNoise
  UserFocusedSearch
  UserOpenedPalette
  UserClosedPalette
  UserToggledBookmark(String)
  UserChangedAnnotation(String)
  UserPressedKey(String)
  ViewportChanged(start: Int, size: Int)
  UserZoomed(Float)
  PageLoaded(query: String, page: EventPage)
  PageLoadFailed(query: String, reason: String)
  UserChangedTrigger(String)
  MfaSuggestionsLoaded(List(String))
  UserChangedCaptureWhere(String)
  UserChangedCapturePreset(String)
  UserChangedMaxRoots(String)
  UserRequestedArm
  CaptureArmAccepted
  CaptureArmFailed(String)
  PollCaptureStatus
  CaptureStatusLoaded(CapturePhase)
  UserRequestedCancel
  CaptureCancelFailed(String)
  UserChangedSavePath(String)
  UserRequestedSave
  CaptureSaved(String)
  CaptureSaveFailed(String)
  PollLive
  LiveLoaded(LiveSnapshot)
  LiveLoadFailed(String)
  UserSelectedLiveProcess(String)
  UserChangedComparePaths(String)
  UserRequestedCompare
  CompareLoaded(CompareReport)
  CompareFailed(String)
}

pub fn init(events: List(EventRow)) -> Model {
  Model(
    remote: False,
    mode: Capture,
    events: events,
    total_events: list.length(events),
    loaded_start: 0,
    loaded_limit: list.length(events),
    loaded_query: "",
    loading: False,
    load_error: None,
    selected_event_id: None,
    query: "",
    show_internal: False,
    viewport_start: 0,
    viewport_size: 80,
    zoom: 1.0,
    palette_open: False,
    search_focused: False,
    bookmarks: [],
    annotation: "",
    trigger_input: "",
    mfa_suggestions: [],
    capture_where: "",
    capture_preset: "generic",
    capture_max_roots: "1",
    save_path: "capture.beamtrace",
    capture_phase: Unavailable,
    capture_notice: "",
    live_rows: [],
    live_findings: [],
    live_supervision: [],
    live_spawn: [],
    live_links: [],
    live_generation: 0,
    live_sampled_at_ms: 0,
    live_loading: False,
    live_error: None,
    selected_live_pid: None,
    compare_paths_input: "baseline.beamtrace\ncandidate.beamtrace",
    compare_loading: False,
    compare_error: None,
    compare_report: None,
  )
}

pub fn init_remote() -> Model {
  Model(
    ..init([]),
    remote: True,
    loading: True,
    loaded_limit: 200,
    viewport_size: 80,
    capture_phase: Idle,
  )
}

pub fn update(model: Model, message: Msg) -> Model {
  case message {
    UserSelectedMode(mode) ->
      Model(
        ..model,
        mode: mode,
        live_loading: case mode {
          Live -> True
          _ -> False
        },
        live_error: case mode {
          Live -> None
          _ -> model.live_error
        },
      )
    UserSelectedEvent(id) -> Model(..model, selected_event_id: Some(id))
    UserChangedQuery(query) ->
      Model(..model, query: query, viewport_start: 0, load_error: None)
    UserToggledInternalNoise ->
      Model(..model, show_internal: !model.show_internal, viewport_start: 0)
    UserFocusedSearch -> Model(..model, search_focused: True)
    UserOpenedPalette -> Model(..model, palette_open: True)
    UserClosedPalette -> Model(..model, palette_open: False)
    UserChangedAnnotation(annotation) -> Model(..model, annotation: annotation)
    UserPressedKey(key) ->
      case keyboard_shortcut(key) {
        Some(message) -> update(model, message)
        None -> model
      }
    UserToggledBookmark(id) ->
      Model(..model, bookmarks: toggle_member(model.bookmarks, id))
    ViewportChanged(start, size) ->
      Model(
        ..model,
        viewport_start: int.max(start, 0),
        viewport_size: int.min(int.max(size, 1), 1000),
        load_error: None,
      )
    UserZoomed(zoom) ->
      Model(..model, zoom: float.clamp(zoom, min: 0.25, max: 4.0))
    PageLoaded(query, page) ->
      case !model.remote || query == remote_query(model) {
        True ->
          Model(
            ..model,
            events: page.events,
            total_events: page.total,
            loaded_start: page.start,
            loaded_limit: page.limit,
            loaded_query: query,
            loading: False,
            load_error: None,
          )
        False -> Model(..model, loading: False)
      }
    PageLoadFailed(query, reason) ->
      case !model.remote || query == remote_query(model) {
        True -> Model(..model, loading: False, load_error: Some(reason))
        False -> Model(..model, loading: False)
      }
    UserChangedTrigger(trigger) ->
      Model(
        ..model,
        trigger_input: trigger,
        mfa_suggestions: case string.trim(trigger) {
          "" -> []
          _ -> model.mfa_suggestions
        },
      )
    MfaSuggestionsLoaded(suggestions) ->
      Model(..model, mfa_suggestions: list.take(suggestions, 200))
    UserChangedCaptureWhere(source) -> Model(..model, capture_where: source)
    UserChangedCapturePreset(preset) -> Model(..model, capture_preset: preset)
    UserChangedMaxRoots(max_roots) ->
      Model(..model, capture_max_roots: max_roots)
    UserRequestedArm ->
      case string.trim(model.trigger_input), parse_root_budget(model) {
        "", _ ->
          Model(
            ..model,
            capture_phase: Failed("trigger_required"),
            capture_notice: "Enter an MFA trigger",
          )
        _, Error(_) ->
          Model(
            ..model,
            capture_phase: Failed("invalid_root_budget"),
            capture_notice: "Max roots must be between 1 and 1000",
          )
        _, Ok(_) ->
          Model(
            ..model,
            capture_phase: Arming,
            capture_notice: "Arming " <> string.trim(model.trigger_input),
          )
      }
    CaptureArmAccepted ->
      Model(
        ..model,
        capture_phase: Armed,
        capture_notice: "Capture armed; perform one operation",
      )
    CaptureArmFailed(reason) ->
      Model(..model, capture_phase: Failed(reason), capture_notice: reason)
    PollCaptureStatus -> model
    CaptureStatusLoaded(phase) ->
      case phase {
        Ready(count, _completeness) ->
          Model(
            ..model,
            capture_phase: phase,
            capture_notice: "",
            total_events: count,
            viewport_start: 0,
            loaded_start: 0,
            loaded_limit: 0,
            loaded_query: "",
            loading: False,
            load_error: None,
          )
        Failed("system_tracer_occupied") ->
          Model(
            ..model,
            capture_phase: phase,
            capture_notice: "Exact capture was refused; another tracer owns the node. Use Live for bounded inferred sampling.",
          )
        _ -> Model(..model, capture_phase: phase)
      }
    UserRequestedCancel ->
      Model(
        ..model,
        capture_phase: Cancelling,
        capture_notice: "Stopping capture and cleaning the target",
      )
    CaptureCancelFailed(reason) ->
      Model(..model, capture_phase: Failed(reason), capture_notice: reason)
    UserChangedSavePath(path) -> Model(..model, save_path: path)
    UserRequestedSave -> Model(..model, capture_notice: "Saving capture")
    CaptureSaved(path) -> Model(..model, capture_notice: "Saved " <> path)
    CaptureSaveFailed(reason) -> Model(..model, capture_notice: reason)
    PollLive ->
      case model.mode {
        Live -> Model(..model, live_loading: True, live_error: None)
        _ -> model
      }
    LiveLoaded(snapshot) ->
      Model(
        ..model,
        live_rows: snapshot.rows,
        live_findings: snapshot.findings,
        live_supervision: snapshot.supervision,
        live_spawn: snapshot.spawn,
        live_links: snapshot.links,
        live_generation: snapshot.generation,
        live_sampled_at_ms: snapshot.sampled_at_ms,
        live_loading: False,
        live_error: None,
      )
    LiveLoadFailed(reason) ->
      Model(..model, live_loading: False, live_error: Some(reason))
    UserSelectedLiveProcess(pid) -> Model(..model, selected_live_pid: Some(pid))
    UserChangedComparePaths(paths) ->
      Model(..model, compare_paths_input: paths, compare_error: None)
    UserRequestedCompare ->
      case valid_compare_paths(compare_paths(model)) {
        True -> Model(..model, compare_loading: True, compare_error: None)
        False ->
          Model(
            ..model,
            compare_loading: False,
            compare_error: Some("Enter 2–20 distinct .beamtrace paths"),
          )
      }
    CompareLoaded(report) ->
      Model(
        ..model,
        compare_loading: False,
        compare_error: None,
        compare_report: Some(report),
      )
    CompareFailed(reason) ->
      Model(..model, compare_loading: False, compare_error: Some(reason))
  }
}

pub fn parse_root_budget(model: Model) -> Result(Int, Nil) {
  case int.parse(string.trim(model.capture_max_roots)) {
    Ok(value) if value >= 1 && value <= 1000 -> Ok(value)
    _ -> Error(Nil)
  }
}

pub fn begin_loading(model: Model) -> Model {
  Model(..model, loading: True, load_error: None)
}

pub fn needs_page(model: Model) -> Bool {
  let requested_end =
    int.min(model.viewport_start + model.viewport_size, model.total_events)
  let loaded_end = model.loaded_start + model.loaded_limit
  let outside_loaded_window =
    model.viewport_start < model.loaded_start || requested_end > loaded_end
  let stale_query = model.loaded_query != remote_query(model)
  model.remote
  && model.mode == Capture
  && !model.loading
  && model.load_error == None
  && { outside_loaded_window || stale_query }
}

pub fn filtered_live_rows(model: Model) -> List(LiveRow) {
  let query = string.lowercase(remote_query(model))
  model.live_rows
  |> list.filter(fn(row) {
    query == ""
    || string.contains(string.lowercase(row.pid), query)
    || string.contains(string.lowercase(row.label), query)
    || string.contains(string.lowercase(row.status), query)
    || string.contains(string.lowercase(row.current_function), query)
  })
}

pub fn selected_live_process(model: Model) -> Result(LiveRow, Nil) {
  case model.selected_live_pid {
    None -> Error(Nil)
    Some(pid) -> list.find(model.live_rows, fn(row) { row.pid == pid })
  }
}

pub fn live_findings_for(model: Model, pid: String) -> List(LiveFinding) {
  list.filter(model.live_findings, fn(finding) { finding.pid == pid })
}

pub fn compare_paths(model: Model) -> List(String) {
  model.compare_paths_input
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(path) { path != "" })
}

fn valid_compare_paths(paths: List(String)) -> Bool {
  let count = list.length(paths)
  count >= 2
  && count <= 20
  && list.all(paths, fn(path) {
    string.ends_with(string.lowercase(path), ".beamtrace")
  })
  && unique_strings(paths, [])
}

fn unique_strings(items: List(String), seen: List(String)) -> Bool {
  case items {
    [] -> True
    [item, ..rest] ->
      case list.contains(seen, item) {
        True -> False
        False -> unique_strings(rest, [item, ..seen])
      }
  }
}

pub fn remote_query(model: Model) -> String {
  string.trim(model.query)
}

pub fn filtered_events(model: Model) -> List(EventRow) {
  let visible_noise =
    model.events
    |> list.filter(fn(row) { model.show_internal || !row.internal })
  case model.remote {
    True ->
      case model.loaded_query == remote_query(model) {
        True -> visible_noise
        False -> []
      }
    False -> {
      let query = string.lowercase(remote_query(model))
      visible_noise
      |> list.filter(fn(row) {
        query == ""
        || string.contains(string.lowercase(row.id), query)
        || string.contains(string.lowercase(row.actor), query)
        || string.contains(string.lowercase(row.kind), query)
      })
    }
  }
}

pub fn visible_events(model: Model) -> List(EventRow) {
  let relative_start = int.max(model.viewport_start - model.loaded_start, 0)
  model
  |> filtered_events
  |> list.drop(relative_start)
  |> list.take(model.viewport_size)
}

pub fn selected_event(model: Model) -> Option(EventRow) {
  case model.selected_event_id {
    None -> None
    Some(id) ->
      model.events |> list.find(fn(row) { row.id == id }) |> result_to_option
  }
}

pub fn keyboard_shortcut(key: String) -> Option(Msg) {
  case string.lowercase(key) {
    "1" -> Some(UserSelectedMode(Capture))
    "2" -> Some(UserSelectedMode(Live))
    "3" -> Some(UserSelectedMode(Compare))
    "/" -> Some(UserFocusedSearch)
    "k" -> Some(UserOpenedPalette)
    _ -> None
  }
}

fn toggle_member(items: List(String), item: String) -> List(String) {
  case list.contains(items, item) {
    True -> list.filter(items, fn(existing) { existing != item })
    False -> [item, ..items]
  }
}

fn result_to_option(result) {
  case result {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}
