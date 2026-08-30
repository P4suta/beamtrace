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
  Team
}

pub type Theme {
  SystemTheme
  LightTheme
  DarkTheme
}

pub type TeamTrace {
  TeamTrace(
    id: String,
    node: String,
    module_: String,
    function_: String,
    arity: Int,
    privacy: String,
    delivery_status: String,
    event_count: Int,
    received_at_ms: Int,
    legal_hold: Bool,
    locked: Bool,
  )
}

pub type TeamTracePage {
  TeamTracePage(traces: List(TeamTrace), next_cursor: Option(String))
}

pub type TeamEventPage {
  TeamEventPage(
    trace_id: String,
    events: List(EventRow),
    next_cursor: Option(String),
  )
}

pub type Evidence {
  Exact
  Inferred(method: String, reason: String)
}

pub type TimeEstimate {
  ExactTime(value_ns: String)
  EstimatedTime(value_ns: String, lower_ns: String, upper_ns: String)
  TimeUnavailable(reason: String)
}

pub type TimeSummary {
  TimeSummary(estimate: TimeEstimate, valid_samples: Int, missing_samples: Int)
}

pub type GraphEdge {
  GraphEdge(from: String, to: String, kind: String, evidence: Evidence)
}

pub type GraphBoundary {
  GraphBoundary(event_id: String, kind: String, reason: String)
}

pub type CapturePhase {
  Unavailable
  Idle
  Arming
  Armed
  Cancelling
  Ready(event_count: Int, outcome_summary: String)
  Failed(reason: String)
}

pub type EventRow {
  EventRow(
    id: String,
    actor: String,
    kind: String,
    timestamp_ns: Int,
    duration_ns: Int,
    time: TimeEstimate,
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
    latency_delta: TimeEstimate,
    reason: String,
  )
}

pub type CompareRun {
  CompareRun(
    path: String,
    added: Int,
    removed: Int,
    changed: Int,
    ambiguity_count: Int,
    first_divergence_path: List(String),
    items: List(CompareItem),
  )
}

pub type BranchStatistic {
  BranchStatistic(
    signature: String,
    p50: TimeSummary,
    p95: TimeSummary,
    occurrences: Int,
    total_runs: Int,
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
    theme: Theme,
    events: List(EventRow),
    graph_edges: List(GraphEdge),
    graph_boundaries: List(GraphBoundary),
    graph_loading: Bool,
    graph_error: Option(String),
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
    capture_form_open: Bool,
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
    team_traces: List(TeamTrace),
    team_next_cursor: Option(String),
    team_loading: Bool,
    team_error: Option(String),
    selected_trace_id: Option(String),
    selected_team_trace_ids: List(String),
    team_events: List(EventRow),
    team_events_next_cursor: Option(String),
    team_events_loading: Bool,
    team_events_error: Option(String),
  )
}

pub type Msg {
  UserSelectedMode(Mode)
  UserCycledTheme
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
  GraphLoaded(edges: List(GraphEdge), boundaries: List(GraphBoundary))
  GraphLoadFailed(reason: String)
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
  UserOpenedCaptureForm
  UserClosedCaptureForm
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
  UserRequestedTeamTraces
  UserRequestedMoreTeamTraces
  TeamTracesLoaded(TeamTracePage)
  TeamTracesFailed(String)
  UserSelectedTeamTrace(String)
  UserToggledTeamCompare(String)
  UserRequestedTeamCompare
  UserRequestedMoreTeamEvents
  TeamEventsLoaded(TeamEventPage)
  TeamEventsFailed(trace_id: String, reason: String)
  UserRequestedTraceHold(trace_id: String, enabled: Bool)
  TraceHoldUpdated(TeamTrace)
  TraceHoldFailed(String)
}

pub fn init(events: List(EventRow)) -> Model {
  Model(
    remote: False,
    mode: Capture,
    theme: SystemTheme,
    events: events,
    graph_edges: [],
    graph_boundaries: [],
    graph_loading: False,
    graph_error: None,
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
    capture_form_open: True,
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
    team_traces: [],
    team_next_cursor: None,
    team_loading: False,
    team_error: None,
    selected_trace_id: None,
    selected_team_trace_ids: [],
    team_events: [],
    team_events_next_cursor: None,
    team_events_loading: False,
    team_events_error: None,
  )
}

pub fn init_remote() -> Model {
  Model(
    ..init([]),
    remote: True,
    loading: True,
    graph_loading: True,
    loaded_limit: 200,
    viewport_size: 80,
    capture_phase: Idle,
  )
}

pub fn update(model: Model, message: Msg) -> Model {
  case message {
    UserCycledTheme -> Model(..model, theme: next_theme(model.theme))
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
        team_loading: case mode, model.team_traces {
          Team, [] -> True
          _, _ -> model.team_loading
        },
        team_error: case mode {
          Team -> None
          _ -> model.team_error
        },
      )
    UserSelectedEvent(id) -> Model(..model, selected_event_id: Some(id))
    UserChangedQuery(query) ->
      Model(..model, query: query, viewport_start: 0, load_error: None)
    UserToggledInternalNoise ->
      Model(..model, show_internal: !model.show_internal, viewport_start: 0)
    UserFocusedSearch -> model
    UserOpenedCaptureForm -> Model(..model, capture_form_open: True)
    UserClosedCaptureForm -> Model(..model, capture_form_open: False)
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
    GraphLoaded(edges, boundaries) ->
      Model(
        ..model,
        graph_edges: edges,
        graph_boundaries: boundaries,
        graph_loading: False,
        graph_error: None,
      )
    GraphLoadFailed(reason) ->
      Model(..model, graph_loading: False, graph_error: Some(reason))
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
        Ready(count, _outcome_summary) ->
          Model(
            ..model,
            capture_phase: phase,
            // A sealed archive that this session never armed opens on its
            // result; the arming form stays reachable behind "New capture".
            capture_form_open: case
              model.capture_phase,
              string.trim(model.trigger_input)
            {
              Idle, "" -> False
              Unavailable, "" -> False
              _, _ -> model.capture_form_open
            },
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
    UserRequestedTeamTraces ->
      Model(
        ..model,
        team_traces: [],
        team_loading: True,
        team_error: None,
        team_next_cursor: None,
      )
    UserRequestedMoreTeamTraces ->
      Model(..model, team_loading: True, team_error: None)
    TeamTracesLoaded(page) ->
      Model(
        ..model,
        team_traces: merge_team_traces(model.team_traces, page.traces),
        team_next_cursor: page.next_cursor,
        team_loading: False,
        team_error: None,
      )
    TeamTracesFailed(reason) ->
      Model(..model, team_loading: False, team_error: Some(reason))
    UserSelectedTeamTrace(id) ->
      case list.find(model.team_traces, fn(trace) { trace.id == id }) {
        Error(_) -> model
        Ok(trace) ->
          Model(
            ..model,
            selected_trace_id: Some(id),
            team_events: [],
            team_events_next_cursor: None,
            team_events_loading: !trace.locked,
            team_events_error: case trace.locked {
              True -> Some("Raw trace content is locked for this role")
              False -> None
            },
          )
      }
    UserToggledTeamCompare(id) ->
      case list.contains(model.selected_team_trace_ids, id) {
        True ->
          Model(
            ..model,
            selected_team_trace_ids: list.filter(
              model.selected_team_trace_ids,
              fn(selected) { selected != id },
            ),
          )
        False ->
          case list.length(model.selected_team_trace_ids) < 20 {
            True ->
              Model(
                ..model,
                selected_team_trace_ids: list.append(
                  model.selected_team_trace_ids,
                  [id],
                ),
              )
            False ->
              Model(
                ..model,
                team_error: Some("Select at most 20 traces for comparison"),
              )
          }
      }
    UserRequestedTeamCompare ->
      case list.length(model.selected_team_trace_ids) >= 2 {
        True ->
          Model(
            ..model,
            mode: Compare,
            compare_paths_input: model.selected_team_trace_ids
              |> list.map(fn(id) { "team:" <> id })
              |> string.join("\n"),
            compare_loading: True,
            compare_error: None,
          )
        False ->
          Model(
            ..model,
            team_error: Some("Select between 2 and 20 traces to compare"),
          )
      }
    UserRequestedMoreTeamEvents ->
      Model(..model, team_events_loading: True, team_events_error: None)
    TeamEventsLoaded(page) ->
      case model.selected_trace_id == Some(page.trace_id) {
        False -> model
        True -> {
          let events =
            list.append(model.team_events, page.events)
            |> list.take(1000)
          Model(
            ..model,
            team_events: events,
            team_events_next_cursor: case list.length(events) >= 1000 {
              True -> None
              False -> page.next_cursor
            },
            team_events_loading: False,
            team_events_error: None,
          )
        }
      }
    TeamEventsFailed(trace_id, reason) ->
      case model.selected_trace_id == Some(trace_id) {
        True ->
          Model(
            ..model,
            team_events_loading: False,
            team_events_error: Some(reason),
          )
        False -> model
      }
    UserRequestedTraceHold(_, _) -> model
    TraceHoldUpdated(updated) ->
      Model(
        ..model,
        team_traces: list.map(model.team_traces, fn(trace) {
          case trace.id == updated.id {
            True -> updated
            False -> trace
          }
        }),
        team_error: None,
      )
    TraceHoldFailed(reason) -> Model(..model, team_error: Some(reason))
  }
}

fn merge_team_traces(
  existing: List(TeamTrace),
  incoming: List(TeamTrace),
) -> List(TeamTrace) {
  list.fold(incoming, existing, fn(traces, incoming_trace) {
    case list.any(traces, fn(trace) { trace.id == incoming_trace.id }) {
      True -> traces
      False -> list.append(traces, [incoming_trace])
    }
  })
  |> list.take(100)
}

fn next_theme(theme: Theme) -> Theme {
  case theme {
    SystemTheme -> LightTheme
    LightTheme -> DarkTheme
    DarkTheme -> SystemTheme
  }
}

pub fn selected_team_trace(model: Model) -> Option(TeamTrace) {
  case model.selected_trace_id {
    None -> None
    Some(id) ->
      model.team_traces
      |> list.find(fn(trace) { trace.id == id })
      |> result_to_option
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
    || string.starts_with(path, "team:")
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
    "4" -> Some(UserSelectedMode(Team))
    "/" -> Some(UserFocusedSearch)
    "k" -> Some(UserOpenedPalette)
    "escape" -> Some(UserClosedPalette)
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
