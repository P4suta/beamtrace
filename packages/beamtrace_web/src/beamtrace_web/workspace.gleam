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
  )
}

pub fn init_remote() -> Model {
  Model(
    ..init([]),
    remote: True,
    loading: True,
    loaded_limit: 200,
    viewport_size: 80,
  )
}

pub fn update(model: Model, message: Msg) -> Model {
  case message {
    UserSelectedMode(mode) -> Model(..model, mode: mode)
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
  && !model.loading
  && model.load_error == None
  && { outside_loaded_window || stale_query }
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
