// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/event
import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import qcheck

pub fn builder_output_equals_the_handwritten_record_test() {
  let checkout = event.process(node: "shop@localhost", pid: "<0.10.0>")
  event.builder(root: "checkout-1", process: checkout)
  |> event.at(offset_ns: 100, order: 1)
  |> event.send(
    id: "send-1",
    to: types.ProcessRef("shop@localhost", "<0.20.0>"),
    message: types.TagOnly("charge"),
    serial: event.serial(previous: 0, current: 1),
  )
  |> should.equal(types.TraceEvent(
    id: "send-1",
    root_id: "checkout-1",
    node: "shop@localhost",
    process: checkout,
    local_instant: types.LocalInstant(100, 1),
    kind: types.Send(
      types.ProcessRef("shop@localhost", "<0.20.0>"),
      types.TagOnly("charge"),
      types.SequenceSerial(0, 1),
    ),
    evidence: types.Exact,
  ))
}

pub fn builder_defaults_are_instant_zero_and_exact_evidence_test() {
  let built =
    event.builder(
      root: "r",
      process: event.process(node: "a@b", pid: "<0.1.0>"),
    )
    |> event.stop(id: "s", reason: "complete")
  built.local_instant |> should.equal(types.LocalInstant(0, 0))
  built.evidence |> should.equal(types.Exact)
}

pub fn actor_carries_logical_identity_without_evidence_test() {
  let identity =
    event.actor(node: "a@b", pid: "<0.1.0>", id: "worker-1", label: "worker")
  identity.physical |> should.equal(types.ProcessRef("a@b", "<0.1.0>"))
  identity.logical
  |> should.equal(Some(types.LogicalActor("worker-1", "worker")))
  identity.evidence |> should.equal([])
}

pub fn node_is_always_derived_from_the_process_test() {
  let built =
    event.builder(
      root: "r",
      process: event.process(node: "leaf@remote", pid: "<0.9.0>"),
    )
    |> event.root(id: "e", trigger: types.Mfa("m", "f", 0), arguments: [])
  built.node |> should.equal("leaf@remote")
}

pub fn inferred_by_attaches_the_stated_inference_test() {
  let built =
    event.builder(
      root: "r",
      process: event.process(node: "a@b", pid: "<0.1.0>"),
    )
    |> event.inferred_by(
      method: "clock-alignment",
      reason: "derived from calibration",
      inputs: [],
    )
    |> event.stop(id: "s", reason: "complete")
  built.evidence
  |> should.equal(
    types.inferred("clock-alignment", "derived from calibration", []),
  )
}

pub fn every_finisher_builds_a_codec_valid_event_test() {
  let process = event.process(node: "shop@localhost", pid: "<0.10.0>")
  let peer = types.ProcessRef("shop@localhost", "<0.20.0>")
  let builder =
    event.builder(root: "r-1", process: process)
    |> event.at(offset_ns: 5, order: 2)

  [
    event.root(
      builder,
      id: "e1",
      trigger: types.Mfa("shop", "checkout", 1),
      arguments: [
        types.TagOnly("order"),
      ],
    ),
    event.send(
      builder,
      id: "e2",
      to: peer,
      message: types.TagOnly("charge"),
      serial: event.serial(previous: 0, current: 1),
    ),
    event.received(
      builder,
      id: "e3",
      from: peer,
      message: types.TagOnly("charge"),
      serial: event.serial(previous: 1, current: 2),
    ),
    event.spawn(
      builder,
      id: "e4",
      child: peer,
      initial_call: types.Mfa("shop", "worker", 0),
    ),
    event.exit(builder, id: "e5", reason: types.TagOnly("normal")),
    event.register(builder, id: "e6", name: "checkout_server"),
    event.link(builder, id: "e7", peer: peer),
    event.metric(builder, id: "e8", name: "queue_len", value: 42.0),
    event.system_signal(builder, id: "e9", name: "long_gc", value: 120),
    event.gap(builder, id: "e10", dropped_events: 3, reason: "overflow"),
    event.stop(builder, id: "e11", reason: "complete"),
  ]
  |> list.each(fn(built) {
    codec.validate_event(built) |> should.equal(Ok(Nil))
  })
}

pub fn built_events_always_satisfy_the_codec_validator_property_test() {
  let ids = qcheck.bounded_int(1, 1_000_000)
  let offsets = qcheck.bounded_int(0, 9_007_199_254_740_991)
  let orders = qcheck.bounded_int(0, 1_000_000)
  let inputs = qcheck.tuple3(ids, offsets, orders)
  let config =
    qcheck.config(
      test_count: 300,
      max_retries: 1,
      seed: qcheck.seed(20_260_902),
    )
  use #(id, offset_ns, order) <- qcheck.run(config, inputs)
  let process = event.process(node: "app@host", pid: "<0.10.0>")
  let built =
    event.builder(root: "root-" <> int.to_string(id), process: process)
    |> event.at(offset_ns: offset_ns, order: order)
    |> event.send(
      id: "send-" <> int.to_string(id),
      to: types.ProcessRef("app@host", "<0.20.0>"),
      message: types.TagOnly("work"),
      serial: event.serial(previous: id - 1, current: id),
    )
  codec.validate_event(built) |> should.equal(Ok(Nil))
}
