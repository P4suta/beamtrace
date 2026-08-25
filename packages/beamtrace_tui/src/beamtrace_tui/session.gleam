// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_tui/model
import etui/backend
import etui/keys
import gleam/int
import gleam/list

pub type CaptureState {
  SessionUnavailable
  SessionIdle
  SessionArmed
  SessionCancelling
  SessionReady(events: List(model.Event), outcome_summary: String)
  SessionFailed(reason: String)
}

pub type LiveState {
  LiveUnavailable(reason: String)
  LiveReady(events: List(model.Event), generation: Int, summary: String)
}

/// Effect boundary owned by the runtime. A TUI reducer cannot claim an attach,
/// arm, cancellation, or save succeeded until the corresponding callback does.
pub type Driver {
  Driver(
    attach: fn(String) -> Result(Nil, String),
    arm: fn(String) -> Result(Nil, String),
    poll: fn() -> CaptureState,
    save: fn(String) -> Result(Nil, String),
    cancel: fn() -> Result(Nil, String),
    live_poll: fn() -> LiveState,
  )
}

pub fn unavailable() -> Driver {
  Driver(
    attach: fn(_) { Error("No target connection is configured") },
    arm: fn(_) { Error("No capture session is available") },
    poll: fn() { SessionUnavailable },
    save: fn(_) { Error("No completed capture is available") },
    cancel: fn() { Error("No capture session is available") },
    live_poll: fn() { LiveUnavailable("No live session is available") },
  )
}

pub fn handle(
  driver: Driver,
  event: backend.InputEvent,
  state: model.Model,
) -> model.Model {
  case event {
    backend.Tick -> {
      let captured = sync(driver.poll(), state)
      case captured.screen {
        model.LiveScreen | model.AnomalyScreen ->
          sync_live(driver.live_poll(), captured)
        _ -> captured
      }
    }
    backend.KeyPress(raw_key) -> handle_key(driver, keys.match(raw_key), state)
    _ -> state
  }
}

pub fn sync_live(status: LiveState, state: model.Model) -> model.Model {
  case status {
    LiveUnavailable(reason) -> model.update(state, model.LiveFailed(reason))
    LiveReady(events, generation, summary) ->
      case generation == state.live_generation {
        True -> state
        False ->
          model.update(state, model.LiveUpdated(events, generation, summary))
      }
  }
}

fn handle_key(
  driver: Driver,
  key: keys.Key,
  state: model.Model,
) -> model.Model {
  case state.focus, key {
    model.AttachFocus, keys.Enter if state.node_input != "" -> {
      let pending = model.update(state, model.AttachSubmitted(state.node_input))
      case driver.attach(state.node_input) {
        Ok(Nil) -> model.update(pending, model.AttachAccepted(state.node_input))
        Error(reason) -> model.update(pending, model.AttachFailed(reason))
      }
    }
    model.ArmFocus, keys.Enter if state.trigger_input != "" -> {
      let pending = model.update(state, model.ArmRequested(state.trigger_input))
      case driver.arm(state.trigger_input) {
        Ok(Nil) -> model.update(pending, model.ArmAccepted(state.trigger_input))
        Error(reason) -> model.update(pending, model.ArmFailed(reason))
      }
    }
    model.SaveFocus, keys.Enter if state.save_input != "" -> {
      let pending = model.update(state, model.SaveRequested(state.save_input))
      case driver.save(state.save_input) {
        Ok(Nil) -> model.update(pending, model.SaveSucceeded(state.save_input))
        Error(reason) -> model.update(pending, model.SaveFailed(reason))
      }
    }
    model.NormalFocus, keys.Char("x") ->
      case driver.cancel() {
        Ok(Nil) -> model.update(state, model.CaptureCancellingStarted)
        Error(reason) -> model.update(state, model.CaptureFailedWith(reason))
      }
    _, _ -> model.handle_key(state, key_name(key))
  }
}

pub fn sync(status: CaptureState, state: model.Model) -> model.Model {
  case status, state.capture_phase {
    SessionUnavailable, _ -> state
    SessionIdle, model.CaptureIdle -> state
    SessionIdle, _ -> model.update(state, model.CaptureBecameIdle)
    SessionArmed, model.CaptureArmed -> state
    SessionArmed, _ -> model.Model(..state, capture_phase: model.CaptureArmed)
    SessionCancelling, model.CaptureCancelling -> state
    SessionCancelling, _ -> model.update(state, model.CaptureCancellingStarted)
    SessionReady(events, outcome_summary), model.CaptureReady(count, current) ->
      case count == list.length(events) && current == outcome_summary {
        True -> state
        False ->
          model.update(state, model.CaptureCompleted(events, outcome_summary))
      }
    SessionReady(events, outcome_summary), _ ->
      model.update(state, model.CaptureCompleted(events, outcome_summary))
    SessionFailed(reason), model.CaptureFailed(current) if reason == current ->
      state
    SessionFailed(reason), _ ->
      model.update(state, model.CaptureFailedWith(reason))
  }
}

fn key_name(key: keys.Key) -> String {
  case key {
    keys.Enter -> "enter"
    keys.Backspace -> "backspace"
    keys.Escape -> "escape"
    keys.Tab -> "tab"
    keys.BackTab -> "backtab"
    keys.Up -> "up"
    keys.Down -> "down"
    keys.Left -> "left"
    keys.Right -> "right"
    keys.Home -> "home"
    keys.End -> "end"
    keys.PageUp -> "pageup"
    keys.PageDown -> "pagedown"
    keys.Delete -> "delete"
    keys.Insert -> "insert"
    keys.Char(value) -> value
    keys.Ctrl(value) -> "ctrl+" <> value
    keys.Alt(value) -> "alt+" <> value
    keys.F(number) -> "f" <> int.to_string(number)
    keys.Unknown(value) -> value
  }
}
