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
          "Inferred 80% · EWMA",
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
  ansi |> string.contains("Inferred 80%") |> should.be_true()
  ansi |> string.contains("supervision 1") |> should.be_true()
}
