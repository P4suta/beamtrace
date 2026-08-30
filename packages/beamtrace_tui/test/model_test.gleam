// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_tui/model
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

fn events() {
  [
    model.Event("root", "checkout", "call", "Exact", 0, False),
    model.Event("send", "checkout", "send", "Exact", 120, False),
    model.Event("receive", "worker", "receive", "Exact", 360, True),
  ]
}

pub fn attach_transitions_to_capture_without_losing_node_test() {
  let state = model.init(events())
  let pending = model.update(state, model.AttachSubmitted("app@localhost"))
  pending.node |> should.equal(None)
  pending.connected |> should.be_false()

  let state = model.update(pending, model.AttachAccepted("app@localhost"))
  state.node |> should.equal(Some("app@localhost"))
  state.screen |> should.equal(model.CaptureScreen)
  state.connected |> should.be_true()
}

pub fn arm_and_save_are_explicit_operations_test() {
  let state = model.init(events())
  let state = model.update(state, model.ArmRequested("checkout:handle/1"))
  state.capture_phase |> should.equal(model.CaptureArming)
  state.armed_trigger |> should.equal(None)

  let state = model.update(state, model.SaveRequested("capture.beamtrace"))
  state.save_path |> should.equal(None)
  state.notice |> should.equal("Saving capture.beamtrace")
}

pub fn vertical_chain_search_preserves_causal_order_test() {
  let state = model.init(events())
  let state = model.update(state, model.SearchChanged("CHECKOUT"))

  model.visible_events(state)
  |> should.equal([
    model.Event("root", "checkout", "call", "Exact", 0, False),
    model.Event("send", "checkout", "send", "Exact", 120, False),
  ])
}

pub fn shortcuts_cover_attach_arm_anomalies_search_save_and_web_test() {
  model.key_to_message("a") |> should.equal(Some(model.OpenAttach))
  model.key_to_message("r") |> should.equal(Some(model.FocusArm))
  model.key_to_message("!") |> should.equal(Some(model.OpenAnomalies))
  model.key_to_message("/") |> should.equal(Some(model.FocusSearch))
  model.key_to_message("s") |> should.equal(Some(model.FocusSave))
  model.key_to_message("w") |> should.equal(Some(model.OpenWeb))
  model.key_to_message("t") |> should.equal(Some(model.OpenTraceLibrary))
}

pub fn team_trace_selection_is_bounded_and_locked_content_stays_closed_test() {
  let traces = [
    model.TeamTrace(
      "metadata-trace",
      "delivered",
      "app@host",
      "shop:checkout/1",
      "metadata",
      10,
      1000,
      False,
    ),
    model.TeamTrace(
      "raw-trace",
      "partial",
      "app@host",
      "shop:raw/0",
      "raw",
      5,
      2000,
      True,
    ),
  ]
  let state = model.remote_with_traces([], "https://hub.example", traces)
  let state = model.handle_key(state, "down")
  state.selected_trace |> should.equal(1)
  let assert Some(selected) = model.selected_team_trace(state)
  selected.id |> should.equal("raw-trace")
  selected.locked |> should.be_true()

  let state = model.handle_key(state, "down")
  state.selected_trace |> should.equal(1)
  let state = model.handle_key(state, "enter")
  state.notice
  |> should.equal("Trace raw-trace is locked by raw-trace policy")
  state.events |> should.equal([])
}

pub fn anomaly_view_only_contains_flagged_events_test() {
  model.init([])
  |> model.update(model.LiveUpdated(events(), 2, "3 processes"))
  |> model.anomalies
  |> should.equal([
    model.Event("receive", "worker", "receive", "Exact", 360, True),
  ])
}

pub fn focused_attach_field_accepts_unicode_backspace_and_enter_test() {
  let state = model.init([])
  let state = model.handle_key(state, "n")
  let state = model.handle_key(state, "ø")
  let state = model.handle_key(state, "backspace")
  let state = model.handle_key(state, "d")
  let state = model.handle_key(state, "e")
  let state = model.handle_key(state, "enter")

  state.node |> should.equal(None)
  state.connected |> should.be_false()
  let state = model.update(state, model.AttachAccepted("nde"))
  state.node |> should.equal(Some("nde"))
  state.connected |> should.be_true()
}

pub fn quit_is_explicit_and_never_bound_to_process_mutation_test() {
  let state = model.init([]) |> model.handle_key("ctrl+c")
  state.quit |> should.be_true()
}

pub fn alt_q_is_global_but_plain_q_remains_valid_focused_input_test() {
  let focused = model.init([]) |> model.handle_key("q")
  focused.node_input |> should.equal("q")
  focused.quit |> should.be_false()

  let quitting = model.init([]) |> model.handle_key("alt+q")
  quitting.quit |> should.be_true()
}

pub fn offline_archive_is_not_misrepresented_as_a_live_connection_test() {
  let state = model.open_archive(events(), Some("app@localhost"))
  state.node |> should.equal(Some("app@localhost"))
  state.connected |> should.be_false()
  state.screen |> should.equal(model.CaptureScreen)
  state.notice |> should.equal("Opened offline trace")
}

pub fn compare_model_keeps_bounded_run_statistics_test() {
  let state =
    model.compare(
      "baseline.beamtrace",
      3,
      [
        model.CompareRunSummary(
          "candidate.beamtrace",
          1,
          2,
          3,
          1,
          "root → send → receive",
        ),
      ],
      4,
    )

  state.screen |> should.equal(model.CompareScreen)
  state.compare_run_count |> should.equal(3)
  state.compare_statistics_count |> should.equal(4)
}

pub fn question_mark_toggles_the_key_guide_and_escape_closes_it_test() {
  let state = model.attached(events(), "app@localhost")
  let opened = model.handle_key(state, "?")
  opened.help_open |> should.be_true()
  model.handle_key(opened, "?").help_open |> should.be_false()
  model.handle_key(opened, "esc").help_open |> should.be_false()
  model.key_guide()
  |> list.any(fn(entry) { entry.0 == "d" && entry.1 == "compare" })
  |> should.be_true()
}
