// SPDX-License-Identifier: Apache-2.0 OR MIT
import etui/keys
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Screen {
  AttachScreen
  CaptureScreen
  LiveScreen
  AnomalyScreen
}

pub type Focus {
  NormalFocus
  AttachFocus
  ArmFocus
  SearchFocus
  SaveFocus
}

pub type Event {
  Event(
    id: String,
    actor: String,
    kind: String,
    evidence: String,
    offset_us: Int,
    anomalous: Bool,
  )
}

pub type Model {
  Model(
    events: List(Event),
    node: Option(String),
    connected: Bool,
    screen: Screen,
    focus: Focus,
    armed_trigger: Option(String),
    query: String,
    save_path: Option(String),
    notice: String,
    open_web_requested: Bool,
    node_input: String,
    trigger_input: String,
    save_input: String,
    quit: Bool,
  )
}

pub type Msg {
  OpenAttach
  FocusArm
  OpenAnomalies
  FocusSearch
  FocusSave
  OpenWeb
  OpenCapture
  OpenLive
  AttachSubmitted(String)
  ArmRequested(String)
  SearchChanged(String)
  SaveRequested(String)
  DismissNotice
}

pub fn init(events: List(Event)) -> Model {
  Model(
    events: events,
    node: None,
    connected: False,
    screen: AttachScreen,
    focus: AttachFocus,
    armed_trigger: None,
    query: "",
    save_path: None,
    notice: "Attach to a BEAM node to begin",
    open_web_requested: False,
    node_input: "",
    trigger_input: "",
    save_input: "capture.beamtrace",
    quit: False,
  )
}

pub fn open_archive(events: List(Event), node: Option(String)) -> Model {
  Model(
    ..init(events),
    node: node,
    connected: False,
    screen: CaptureScreen,
    focus: NormalFocus,
    notice: "Opened offline trace",
  )
}

pub fn remote(events: List(Event), server_url: String) -> Model {
  Model(
    ..init(events),
    screen: LiveScreen,
    focus: NormalFocus,
    notice: "Server " <> server_url,
  )
}

pub fn update(model: Model, message: Msg) -> Model {
  case message {
    OpenAttach -> Model(..model, screen: AttachScreen, focus: AttachFocus)
    FocusArm -> Model(..model, screen: CaptureScreen, focus: ArmFocus)
    OpenAnomalies -> Model(..model, screen: AnomalyScreen, focus: NormalFocus)
    FocusSearch -> Model(..model, focus: SearchFocus)
    FocusSave -> Model(..model, focus: SaveFocus)
    OpenWeb ->
      Model(
        ..model,
        open_web_requested: True,
        notice: "Open the Web workspace for free graph and advanced diff",
      )
    OpenCapture -> Model(..model, screen: CaptureScreen, focus: NormalFocus)
    OpenLive -> Model(..model, screen: LiveScreen, focus: NormalFocus)
    AttachSubmitted(node) ->
      Model(
        ..model,
        node: Some(node),
        connected: True,
        screen: CaptureScreen,
        focus: NormalFocus,
        notice: "Attached " <> node,
      )
    ArmRequested(trigger) ->
      Model(
        ..model,
        armed_trigger: Some(trigger),
        screen: CaptureScreen,
        focus: NormalFocus,
        notice: "Armed " <> trigger,
      )
    SearchChanged(query) -> Model(..model, query: query, focus: SearchFocus)
    SaveRequested(path) ->
      Model(
        ..model,
        save_path: Some(path),
        focus: NormalFocus,
        notice: "Saved " <> path,
      )
    DismissNotice -> Model(..model, notice: "")
  }
}

pub fn visible_events(model: Model) -> List(Event) {
  let query = model.query |> string.trim |> string.lowercase
  case query {
    "" -> model.events
    _ ->
      list.filter(model.events, fn(event) {
        string.contains(string.lowercase(event.id), query)
        || string.contains(string.lowercase(event.actor), query)
        || string.contains(string.lowercase(event.kind), query)
      })
  }
}

pub fn anomalies(model: Model) -> List(Event) {
  list.filter(model.events, fn(event) { event.anomalous })
}

pub fn key_to_message(key: String) -> Option(Msg) {
  case string.lowercase(key) {
    "a" -> Some(OpenAttach)
    "r" -> Some(FocusArm)
    "!" -> Some(OpenAnomalies)
    "/" -> Some(FocusSearch)
    "s" -> Some(FocusSave)
    "w" -> Some(OpenWeb)
    "c" -> Some(OpenCapture)
    "l" -> Some(OpenLive)
    _ -> None
  }
}

/// Pure terminal input reducer. No capture or process mutation is performed by
/// key handling; those operations are emitted as explicit model messages.
pub fn handle_key(model: Model, raw_key: String) -> Model {
  let key = keys.match(raw_key)
  case model.focus {
    AttachFocus -> handle_attach_key(model, key)
    ArmFocus -> handle_arm_key(model, key)
    SearchFocus -> handle_search_key(model, key)
    SaveFocus -> handle_save_key(model, key)
    NormalFocus -> handle_normal_key(model, key)
  }
}

fn handle_attach_key(model: Model, key: keys.Key) -> Model {
  case key {
    keys.Enter ->
      case model.node_input == "" {
        True -> Model(..model, notice: "Node name is required")
        False -> update(model, AttachSubmitted(model.node_input))
      }
    keys.Backspace -> Model(..model, node_input: drop_last(model.node_input))
    keys.Escape -> Model(..model, focus: NormalFocus)
    keys.Char(value) -> Model(..model, node_input: model.node_input <> value)
    keys.Ctrl("c") -> Model(..model, quit: True)
    _ -> model
  }
}

fn handle_arm_key(model: Model, key: keys.Key) -> Model {
  case key {
    keys.Enter ->
      case model.trigger_input == "" {
        True -> Model(..model, notice: "MFA trigger is required")
        False -> update(model, ArmRequested(model.trigger_input))
      }
    keys.Backspace ->
      Model(..model, trigger_input: drop_last(model.trigger_input))
    keys.Escape -> Model(..model, focus: NormalFocus)
    keys.Char(value) ->
      Model(..model, trigger_input: model.trigger_input <> value)
    keys.Ctrl("c") -> Model(..model, quit: True)
    _ -> model
  }
}

fn handle_search_key(model: Model, key: keys.Key) -> Model {
  case key {
    keys.Enter | keys.Escape -> Model(..model, focus: NormalFocus)
    keys.Backspace -> update(model, SearchChanged(drop_last(model.query)))
    keys.Char(value) -> update(model, SearchChanged(model.query <> value))
    keys.Ctrl("c") -> Model(..model, quit: True)
    _ -> model
  }
}

fn handle_save_key(model: Model, key: keys.Key) -> Model {
  case key {
    keys.Enter ->
      case model.save_input == "" {
        True -> Model(..model, notice: "Save path is required")
        False -> update(model, SaveRequested(model.save_input))
      }
    keys.Backspace -> Model(..model, save_input: drop_last(model.save_input))
    keys.Escape -> Model(..model, focus: NormalFocus)
    keys.Char(value) -> Model(..model, save_input: model.save_input <> value)
    keys.Ctrl("c") -> Model(..model, quit: True)
    _ -> model
  }
}

fn handle_normal_key(model: Model, key: keys.Key) -> Model {
  case key {
    keys.Char("q") | keys.Ctrl("c") -> Model(..model, quit: True)
    keys.Char(value) ->
      case key_to_message(value) {
        Some(message) -> update(model, message)
        None -> model
      }
    _ -> model
  }
}

fn drop_last(value: String) -> String {
  string.drop_end(value, 1)
}
