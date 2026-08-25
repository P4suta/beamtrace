// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/capture
import beamtrace_runtime/capture_session
import beamtrace_runtime/live
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should
import v2_fixture

pub fn arm_runs_capture_off_the_caller_and_exposes_the_completed_result_test() {
  let expected = v2_fixture.capture_result([event("root")])
  let session =
    capture_session.new_with_backend(fn(spec) {
      spec.trigger |> should.equal(types.Mfa("shop", "checkout", 1))
      Ok(expected)
    })

  capture_session.status(session)
  |> should.equal(capture_session.Idle)
  capture_session.arm(session, arm_spec()) |> should.equal(Ok(Nil))

  capture_session.await(session, 1000) |> should.equal(Ok(expected))
  capture_session.status(session)
  |> should.equal(capture_session.Ready(
    1,
    "sealed_after_quiet_period:250:delivery_verified",
  ))
  capture_session.close(session)
}

pub fn a_second_arm_is_rejected_while_capture_is_running_test() {
  let session =
    capture_session.new_with_backend(fn(_spec) {
      process.sleep(100)
      Ok(v2_fixture.capture_result([]))
    })

  capture_session.arm(session, arm_spec()) |> should.equal(Ok(Nil))
  capture_session.arm(session, arm_spec())
  |> should.equal(Error(capture_session.CaptureAlreadyRunning))
  capture_session.await(session, 1000) |> should.be_ok
  capture_session.close(session)
}

pub fn failed_capture_remains_an_explicit_session_status_test() {
  let session =
    capture_session.new_with_backend(fn(_spec) {
      Error("system_tracer_occupied")
    })

  capture_session.arm(session, arm_spec()) |> should.equal(Ok(Nil))
  capture_session.await(session, 1000)
  |> should.equal(
    Error(capture_session.CaptureFailed("system_tracer_occupied")),
  )
  capture_session.status(session)
  |> should.equal(capture_session.Failed("system_tracer_occupied"))
  capture_session.close(session)
}

pub fn session_scopes_mfa_search_to_its_owned_nodes_test() {
  let session =
    capture_session.new_with_backends_for_nodes(
      ["app@host"],
      fn(_) { Ok(v2_fixture.capture_result([])) },
      fn(node, query, limit) {
        node |> should.equal("app@host")
        query |> should.equal("checkout")
        limit |> should.equal(20)
        Ok([capture.MfaCandidate(node, "shop", "checkout", 1)])
      },
    )

  capture_session.search_mfas(session, "app@host", "checkout", 20)
  |> should.equal(
    Ok([
      capture.MfaCandidate("app@host", "shop", "checkout", 1),
    ]),
  )
  capture_session.search_mfas(session, "other@host", "", 20)
  |> should.equal(
    Error(capture_session.InvalidSessionRequest("target_not_owned")),
  )
  capture_session.close(session)
}

pub fn live_samples_are_shared_within_ttl_and_rotate_bounded_shards_test() {
  let first = process_sample("<0.1.0>", 1)
  let second = process_sample("<0.2.0>", 7)
  let session =
    capture_session.new_with_live_backend_for_nodes(
      ["app@host"],
      fn(_) { Ok(v2_fixture.capture_result([])) },
      fn(_node, offset, limit) {
        limit |> should.equal(20)
        case offset {
          0 -> Ok(#([first], 7))
          7 -> Ok(#([second], 0))
          _ -> Error("unexpected_offset")
        }
      },
    )

  let assert Ok(initial) =
    capture_session.live_snapshot_at(
      session,
      "app@host",
      20,
      now_ms: 1000,
      ttl_ms: 500,
    )
  let assert Ok(shared) =
    capture_session.live_snapshot_at(
      session,
      "app@host",
      20,
      now_ms: 1200,
      ttl_ms: 500,
    )
  shared |> should.equal(initial)

  let assert Ok(next) =
    capture_session.live_snapshot_at(
      session,
      "app@host",
      20,
      now_ms: 1600,
      ttl_ms: 500,
    )
  next.generation |> should.equal(initial.generation + 1)
  next.previous |> should.equal([first])
  next.samples |> should.equal([second])
  capture_session.close(session)
}

fn arm_spec() -> capture_session.ArmSpec {
  capture_session.ArmSpec(
    trigger: types.Mfa("shop", "checkout", 1),
    where_aql: None,
    capture_window_ms: 1000,
    drain_timeout_ms: 10_000,
    budget: capture.default_budget(),
    max_roots: 1,
    preset: types.Generic,
  )
}

fn event(id: String) -> types.TraceEvent {
  let process = types.ProcessRef("app@host", "<0.1.0>")
  types.TraceEvent(
    id: id,
    root_id: "root",
    node: "app@host",
    process: types.ProcessIdentity(process, None, []),
    local_instant: v2_fixture.instant(1),
    kind: types.Root(types.Mfa("shop", "checkout", 1), []),
    evidence: types.Exact,
  )
}

fn process_sample(pid: String, mailbox: Int) -> live.ProcessSample {
  live.ProcessSample(
    "app@host",
    pid,
    pid,
    "",
    "",
    "worker:start/0",
    mailbox,
    1000,
    10,
    20,
    30,
    0,
    "waiting",
    "worker:loop/0",
    [],
    [],
  )
}
