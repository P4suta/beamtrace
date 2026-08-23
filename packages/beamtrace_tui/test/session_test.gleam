// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_tui/model
import beamtrace_tui/session
import etui/backend
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn driver(
  arm arm: fn(String) -> Result(Nil, String),
  poll poll: fn() -> session.CaptureState,
  save save: fn(String) -> Result(Nil, String),
) -> session.Driver {
  session.Driver(
    attach: fn(_) { Ok(Nil) },
    arm: arm,
    poll: poll,
    save: save,
    cancel: fn() { Ok(Nil) },
    live_poll: fn() { session.LiveUnavailable("not_requested") },
  )
}

pub fn live_ticks_update_a_separate_bounded_snapshot_without_losing_capture_test() {
  let captured = [model.Event("root", "checkout", "call", "Exact", 0, False)]
  let sampled = [
    model.Event(
      "<0.42.0>",
      "orders worker",
      "mailbox_growth · mailbox is growing above its baseline",
      "Inferred 80% · EWMA exceeded baseline with hysteresis",
      7,
      True,
    ),
  ]
  let live_driver =
    session.Driver(
      attach: fn(_) { Ok(Nil) },
      arm: fn(_) { Ok(Nil) },
      poll: fn() { session.SessionReady(captured, "complete") },
      save: fn(_) { Ok(Nil) },
      cancel: fn() { Ok(Nil) },
      live_poll: fn() {
        session.LiveReady(sampled, 7, "1 process · supervision 1 · links 1")
      },
    )
  let state =
    model.attached([], "app@localhost")
    |> model.update(model.OpenLive)
    |> fn(state) { session.handle(live_driver, backend.Tick, state) }

  state.events |> should.equal(captured)
  state.live_events |> should.equal(sampled)
  state.live_generation |> should.equal(7)
  state.live_summary |> should.equal("1 process · supervision 1 · links 1")
  model.anomalies(state) |> should.equal(sampled)
}

fn arm_input() -> model.Model {
  let state = model.attached([], "app@localhost")
  let state = model.update(state, model.FocusArm)
  "shop:checkout/1"
  |> string.to_graphemes
  |> list.fold(state, fn(state, value) { model.handle_key(state, value) })
}

pub fn arm_success_is_reported_only_after_the_backend_accepts_it_test() {
  let state =
    session.handle(
      driver(
        arm: fn(trigger) {
          trigger |> should.equal("shop:checkout/1")
          Ok(Nil)
        },
        poll: fn() { session.SessionArmed },
        save: fn(_) { Error("not_ready") },
      ),
      backend.KeyPress("enter"),
      arm_input(),
    )

  state.capture_phase |> should.equal(model.CaptureArmed)
  state.armed_trigger |> should.equal(Some("shop:checkout/1"))
  state.notice |> should.equal("Capture armed; perform one operation")
}

pub fn arm_failure_is_never_presented_as_success_test() {
  let state =
    session.handle(
      driver(
        arm: fn(_) { Error("system_tracer_occupied") },
        poll: fn() { session.SessionIdle },
        save: fn(_) { Error("not_ready") },
      ),
      backend.KeyPress("enter"),
      arm_input(),
    )

  state.capture_phase
  |> should.equal(model.CaptureFailed("system_tracer_occupied"))
  state.armed_trigger |> should.equal(None)
  state.notice |> should.equal("system_tracer_occupied")
}

pub fn ticks_load_the_completed_causal_chain_and_completeness_test() {
  let rows = [model.Event("root", "checkout", "call", "Exact", 0, False)]
  let state =
    session.handle(
      driver(
        arm: fn(_) { Ok(Nil) },
        poll: fn() { session.SessionReady(rows, "complete") },
        save: fn(_) { Ok(Nil) },
      ),
      backend.Tick,
      model.attached([], "app@localhost"),
    )

  state.events |> should.equal(rows)
  state.capture_phase |> should.equal(model.CaptureReady(1, "complete"))
  state.notice |> should.equal("Capture complete")
}

pub fn save_notice_reflects_the_real_backend_result_test() {
  let state =
    model.attached([], "app@localhost")
    |> model.update(model.CaptureCompleted([], "complete"))
    |> model.update(model.FocusSave)

  let saved =
    session.handle(
      driver(
        arm: fn(_) { Ok(Nil) },
        poll: fn() { session.SessionIdle },
        save: fn(path) {
          path |> should.equal("capture.beamtrace")
          Ok(Nil)
        },
      ),
      backend.KeyPress("enter"),
      state,
    )
  saved.save_path |> should.equal(Some("capture.beamtrace"))
  saved.notice |> should.equal("Saved capture.beamtrace")

  let failed =
    session.handle(
      driver(
        arm: fn(_) { Ok(Nil) },
        poll: fn() { session.SessionIdle },
        save: fn(_) { Error("disk_full") },
      ),
      backend.KeyPress("enter"),
      state,
    )
  failed.save_path |> should.equal(None)
  failed.notice |> should.equal("disk_full")
}
