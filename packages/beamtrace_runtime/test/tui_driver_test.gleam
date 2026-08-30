// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/capture_session
import beamtrace_runtime/live
import beamtrace_runtime/storage
import beamtrace_runtime/tui_driver
import beamtrace_tui/session
import gleam/list
import gleam/option.{None}
import gleeunit/should
import v2_fixture

pub fn tui_driver_arms_polls_and_saves_the_owned_capture_test() {
  let expected = v2_fixture.capture_result([event()])
  let store =
    capture_session.new_with_backend_for_nodes(["fixture@host"], fn(spec) {
      spec.trigger |> should.equal(types.Mfa("shop", "checkout", 1))
      Ok(expected)
    })
  let driver = tui_driver.new(store, "0.1.0")

  driver.attach("other@host") |> should.equal(Error("target_not_owned"))
  driver.attach("fixture@host") |> should.equal(Ok(Nil))
  driver.arm("invalid")
  |> should.equal(Error("invalid MFA 'invalid': expected Module:function/arity"))
  driver.arm("shop:checkout/1") |> should.equal(Ok(Nil))
  capture_session.await(store, 1000) |> should.equal(Ok(expected))

  case driver.poll() {
    session.SessionReady(
      rows,
      "sealed_after_quiet_period:250:delivery_verified",
    ) -> {
      rows |> list.length |> should.equal(1)
      let assert [row] = rows
      row.id |> should.equal("root")
    }
    _ -> should.fail()
  }

  let path = "build/tui-driver-capture.beamtrace"
  driver.save(path) |> should.equal(Ok(Nil))
  let assert Ok(archive) = storage.load(path)
  archive.events |> should.equal([event()])
  archive.manifest.nodes |> should.equal(["fixture@host"])
  capture_session.close(store)
}

pub fn tui_driver_refuses_non_archive_paths_and_save_before_ready_test() {
  let store =
    capture_session.new_with_backend(fn(_) { Ok(v2_fixture.capture_result([])) })
  let driver = tui_driver.new(store, "0.1.0")

  driver.save("capture.zip")
  |> should.equal(Error("save_path_must_end_in_.beamtrace"))
  driver.save("capture.beamtrace")
  |> should.equal(Error("capture_not_ready"))
  capture_session.close(store)
}

pub fn tui_driver_reads_shared_live_metadata_without_replacing_capture_events_test() {
  let store =
    capture_session.new_with_live_backend_for_nodes(
      ["fixture@host"],
      fn(_) { Error("capture_unused") },
      fn(_node, offset, limit) {
        limit |> should.equal(200)
        Ok(#(
          [
            live.ProcessSample(
              "fixture@host",
              "<0.42.0>",
              "orders worker",
              "orders",
              "orders worker",
              "orders_worker:init/1",
              50,
              10_000,
              1000,
              100,
              200,
              1,
              "waiting",
              "gen_server:loop/7",
              ["<0.7.0>"],
              ["orders_sup"],
            ),
          ],
          offset + 1,
        ))
      },
    )
  let driver = tui_driver.new(store, "0.1.0")
  case driver.live_poll() {
    session.LiveReady([row], 1, summary) -> {
      row.id |> should.equal("<0.42.0>")
      row.actor |> should.equal("orders worker")
      row.kind
      |> should.equal("waiting · mailbox=50 · memory=10000 · reductions=1000")
      row.evidence |> should.equal("Exact sample")
      summary |> should.equal("1 process · supervision 1 · spawn 0 · links 1")
    }
    _ -> should.fail()
  }
  capture_session.close(store)
}

fn event() -> types.TraceEvent {
  let process = types.ProcessRef("fixture@host", "<0.1.0>")
  types.TraceEvent(
    id: "root",
    root_id: "root",
    node: "fixture@host",
    process: types.ProcessIdentity(process, None, []),
    local_instant: v2_fixture.instant(1),
    kind: types.Root(types.Mfa("shop", "checkout", 1), []),
    evidence: types.Exact,
  )
}
