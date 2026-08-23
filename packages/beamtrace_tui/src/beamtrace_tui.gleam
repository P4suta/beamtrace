// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_tui/adapter
import beamtrace_tui/model
import beamtrace_tui/view
import etui/app
import etui/backend
import etui/backend/default
import gleam/option.{None, Some}

pub fn main() {
  run_archive([], [])
}

pub fn run_archive(events: List(types.TraceEvent), nodes: List(String)) {
  let node = case nodes {
    [first, ..] -> Some(first)
    [] -> None
  }
  run_model(model.open_archive(adapter.from_trace(events), node))
}

pub fn run_attached(events: List(types.TraceEvent), node: String) {
  let state =
    events
    |> adapter.from_trace
    |> model.init
    |> model.update(model.AttachSubmitted(node))
  run_model(state)
}

pub fn run_remote(server_url: String) {
  run_model(model.remote([], server_url))
}

fn run_model(initial: model.Model) {
  let _ =
    app.run_buffered(
      default.new(),
      initial,
      view.render,
      on_input,
      fn(state) { state.quit },
      16,
    )
  Nil
}

fn on_input(event: backend.InputEvent, state: model.Model) -> model.Model {
  case event {
    backend.KeyPress(key) -> model.handle_key(state, key)
    _ -> state
  }
}
