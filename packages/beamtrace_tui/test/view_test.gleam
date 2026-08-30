// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_tui/model
import beamtrace_tui/view
import etui/buffer
import etui/geometry
import gleam/string
import gleeunit/should

pub fn headless_render_contains_vertical_chain_and_safety_state_test() {
  let state =
    model.init([
      model.Event("e-1", "checkout", "call", "Exact", 0, False),
      model.Event("e-2", "worker", "exit", "Exact", 420, True),
    ])
  let state = model.update(state, model.AttachAccepted("app@localhost"))
  let ansi =
    view.render(state, geometry.rect_new(0, 0, 110, 32))
    |> buffer.to_ansi

  ansi |> string.contains("BeamTrace") |> should.be_true()
  ansi |> string.contains("CAPTURE") |> should.be_true()
  ansi |> string.contains("e-1") |> should.be_true()
  ansi |> string.contains("e-2") |> should.be_true()
  ansi |> string.contains("metadata") |> should.be_true()
  ansi |> string.contains("q quit") |> should.be_true()
  ansi |> string.contains("#1042") |> should.be_false()
}

pub fn headless_live_render_uses_sampled_processes_and_inference_evidence_test() {
  let state =
    model.attached([], "app@localhost")
    |> model.update(model.OpenLive)
    |> model.update(model.LiveUpdated(
      [
        model.Event(
          "<0.42.0>",
          "orders worker",
          "mailbox_growth · mailbox is growing",
          "Inferred · ewma_hysteresis_v2 · EWMA",
          2,
          True,
        ),
      ],
      2,
      "1 process · supervision 1 · links 1",
    ))
  let ansi =
    view.render(state, geometry.rect_new(0, 0, 110, 32))
    |> buffer.to_ansi

  ansi |> string.contains("orders worker") |> should.be_true()
  ansi |> string.contains("mailbox_growth") |> should.be_true()
  ansi |> string.contains("Inferred · ewma_hysteresis_v2") |> should.be_true()
  ansi |> string.contains("supervision 1") |> should.be_true()
}

pub fn responsive_layout_uses_three_two_and_one_real_panels_test() {
  let state =
    model.attached(
      [model.Event("event-responsive", "worker", "send", "Exact", 1, False)],
      "app@localhost",
    )
  let wide =
    view.render(state, geometry.rect_new(0, 0, 100, 24))
    |> buffer.to_ansi
  wide |> string.contains("NODE / SESSION") |> should.be_true()
  wide |> string.contains("EVENT / ACTIONS") |> should.be_true()
  wide |> string.contains("event-responsive") |> should.be_true()

  let medium =
    view.render(state, geometry.rect_new(0, 0, 72, 24))
    |> buffer.to_ansi
  medium |> string.contains("NODE / SESSION") |> should.be_false()
  medium |> string.contains("EVENT / ACTIONS") |> should.be_true()
  medium |> string.contains("event-responsive") |> should.be_true()

  let narrow =
    view.render(state, geometry.rect_new(0, 0, 71, 24))
    |> buffer.to_ansi
  narrow |> string.contains("NODE / SESSION") |> should.be_false()
  narrow |> string.contains("EVENT / ACTIONS") |> should.be_false()
  narrow |> string.contains("event-responsive") |> should.be_true()
}

pub fn event_rows_use_cell_aware_truncation_for_cjk_and_emoji_test() {
  let actor = "注文😀注文😀注文😀注文😀注文😀注文😀注文😀注文😀"
  let state =
    model.attached(
      [model.Event("wide-event", actor, "送信 combining-é", "Exact", 1, False)],
      "app@localhost",
    )
  let ansi =
    view.render(state, geometry.rect_new(0, 0, 72, 20))
    |> buffer.to_ansi

  ansi |> string.contains("wide-event") |> should.be_true()
  ansi |> string.contains("…") |> should.be_true()
  ansi |> string.contains(actor) |> should.be_false()
}

pub fn team_trace_selector_shows_locked_rows_and_selection_test() {
  let traces = [
    model.TeamTrace(
      "trace-metadata",
      "delivered",
      "app@host",
      "shop:checkout/1",
      "metadata",
      12,
      1000,
      False,
    ),
    model.TeamTrace(
      "trace-raw",
      "partial",
      "worker@host",
      "orders:run/0",
      "raw",
      3,
      2000,
      True,
    ),
  ]
  let state = model.remote_with_traces([], "https://hub.example", traces)
  let ansi =
    view.render(state, geometry.rect_new(0, 0, 100, 24))
    |> buffer.to_ansi
  ansi |> string.contains("TRACE LIBRARY") |> should.be_true()
  ansi |> string.contains("trace-metadata") |> should.be_true()
  ansi |> string.contains("trace-raw") |> should.be_true()
  ansi |> string.contains("🔒") |> should.be_true()
}

pub fn compare_screen_renders_count_statistics_and_first_divergence_test() {
  let state =
    model.compare(
      "baseline.beamtrace",
      3,
      [
        model.CompareRunSummary(
          "candidate.beamtrace",
          1,
          0,
          2,
          1,
          "root → send → receive",
        ),
      ],
      5,
    )
  let ansi =
    view.render(state, geometry.rect_new(0, 0, 140, 40))
    |> buffer.to_ansi

  ansi |> string.contains("MULTI-TRACE ALIGNMENT") |> should.be_true()
  ansi |> string.contains("3 traces") |> should.be_true()
  ansi |> string.contains("5 branch signatures") |> should.be_true()
  ansi |> string.contains("root → send → receive") |> should.be_true()
}
