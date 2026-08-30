// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_tui/adapter
import beamtrace_tui/model
import beamtrace_tui/session
import beamtrace_tui/view
import etui/app
import etui/backend/default
import gleam/option.{None, Some}

pub fn main() {
  run_model(session.unavailable(), model.init([]))
}

pub fn run_archive(events: List(types.TraceEvent), nodes: List(String)) {
  let node = case nodes {
    [first, ..] -> Some(first)
    [] -> None
  }
  run_model(
    session.unavailable(),
    model.open_archive(adapter.from_trace(events), node),
  )
}

pub fn run_attached(events: List(types.TraceEvent), node: String) {
  run_attached_with_driver(events, node, session.unavailable())
}

pub fn run_attached_with_driver(
  events: List(types.TraceEvent),
  node: String,
  driver: session.Driver,
) {
  run_model(driver, model.attached(adapter.from_trace(events), node))
}

pub fn run_remote(server_url: String) {
  run_model(session.unavailable(), model.remote([], server_url))
}

pub fn run_remote_with_traces(
  server_url: String,
  traces: List(model.TeamTrace),
) {
  run_model(
    session.unavailable(),
    model.remote_with_traces([], server_url, traces),
  )
}

/// Open the terminal-native multi-trace comparison screen. Runtime callers
/// provide only bounded summaries, keeping archive I/O outside the TUI.
pub fn run_compare(
  baseline: String,
  run_count: Int,
  runs: List(model.CompareRunSummary),
  statistics_count: Int,
) {
  run_model(
    session.unavailable(),
    model.compare(baseline, run_count, runs, statistics_count),
  )
}

fn run_model(driver: session.Driver, initial: model.Model) {
  let _ =
    app.run_buffered(
      default.new(),
      initial,
      view.render,
      fn(event, state) { session.handle(driver, event, state) },
      fn(state) { state.quit },
      16,
    )
  Nil
}
