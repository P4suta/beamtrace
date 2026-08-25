// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/diagnostics
import beamtrace/types
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

fn identity(pid: String) {
  types.ProcessIdentity(types.ProcessRef("app@host", pid), None, [])
}

fn logical_identity(pid: String, slot: String) {
  types.ProcessIdentity(
    types.ProcessRef("app@host", pid),
    Some(types.LogicalActor(slot, slot)),
    [types.SupervisorChildId(slot)],
  )
}

fn verified_outcome() {
  types.CaptureOutcome(types.QuietPeriod(250), [], [
    types.NodeReceipt("app@host", 1, 1, 1),
  ])
}

fn send(
  id: String,
  from: String,
  to: String,
  tag: String,
  serial: Int,
  at: Int,
) {
  types.TraceEvent(
    id,
    "root",
    "app@host",
    identity(from),
    types.LocalInstant(at, at),
    types.Send(
      types.ProcessRef("app@host", to),
      types.Tag(tag),
      types.SequenceSerial(serial - 1, serial),
    ),
    types.Exact,
  )
}

fn received(
  id: String,
  to: String,
  from: String,
  tag: String,
  serial: Int,
  at: Int,
) {
  types.TraceEvent(
    id,
    "root",
    "app@host",
    identity(to),
    types.LocalInstant(at, at),
    types.Received(
      types.ProcessRef("app@host", from),
      types.Tag(tag),
      types.SequenceSerial(serial - 1, serial),
    ),
    types.Exact,
  )
}

pub fn hot_sender_and_fan_in_are_explained_from_exact_counts_test() {
  let events = [
    send("s1", "<0.1.0>", "<0.9.0>", "message", 1, 1),
    send("s2", "<0.1.0>", "<0.9.0>", "message", 2, 2),
    send("s3", "<0.2.0>", "<0.9.0>", "message", 3, 3),
    received("r1", "<0.9.0>", "<0.1.0>", "message", 1, 4),
    received("r2", "<0.9.0>", "<0.2.0>", "message", 3, 5),
  ]

  let assert [hot] = diagnostics.hot_senders(events, minimum_messages: 2)
  hot.kind |> should.equal(diagnostics.HotSender)
  hot.value |> should.equal(diagnostics.CountValue(2))
  let assert types.Inferred(types.Inference(hot_method, _, hot_inputs)) =
    hot.evidence
  hot_method |> should.equal("observed_hot_sender_count_v2")
  list.contains(hot_inputs, types.AlgorithmSetting("minimum_messages", "2"))
  |> should.be_true()

  let assert [fan_in] = diagnostics.fan_in(events, minimum_senders: 2)
  fan_in.kind |> should.equal(diagnostics.FanIn)
  fan_in.value |> should.equal(diagnostics.CountValue(2))
}

pub fn queue_wait_uses_same_node_serial_pair_only_test() {
  diagnostics.queue_waits(
    [
      send("s", "<0.1.0>", "<0.2.0>", "call", 7, 100),
      received("r", "<0.2.0>", "<0.1.0>", "call", 7, 180),
    ],
    minimum_ns: 50,
  )
  |> should.equal([
    diagnostics.Finding(
      kind: diagnostics.QueueWait,
      summary: "message waited 80ns before receive",
      evidence: types.inferred(
        "full_serial_same_node_queue_wait_v2",
        "a unique full-serial pair shares one node-local clock",
        [
          types.ObservedValue("duration_ns", "80"),
          types.AlgorithmSetting("minimum_ns", "50"),
          types.EvidenceEvent("s"),
          types.EvidenceEvent("r"),
        ],
      ),
      event_ids: ["s", "r"],
      value: diagnostics.TimeValue(types.ExactTime(80)),
    ),
  ])
}

pub fn dangling_call_is_inferred_and_reply_closes_it_test() {
  let call = send("call", "<0.1.0>", "<0.2.0>", "call", 10, 100)
  let findings =
    diagnostics.dangling_calls(
      [call],
      outcome: verified_outcome(),
      now_ns: 1000,
      timeout_ns: 500,
    )
  let assert [finding] = findings
  finding.kind |> should.equal(diagnostics.DanglingCall)
  finding.evidence
  |> should.equal(
    types.inferred(
      "delivery_verified_missing_reply_v2",
      "no reverse reply was observed before the timeout in a verified capture",
      [
        types.EvidenceEvent("call"),
        types.ObservedValue("age_ns", "900"),
        types.AlgorithmSetting("timeout_ns", "500"),
        types.AlgorithmSetting("endpoint_pairing", "unique_call_endpoints"),
      ],
    ),
  )

  diagnostics.dangling_calls(
    [call, send("reply", "<0.2.0>", "<0.1.0>", "reply", 11, 200)],
    outcome: verified_outcome(),
    now_ns: 1000,
    timeout_ns: 500,
  )
  |> should.equal([])
}

pub fn restart_chain_links_exit_spawn_and_new_pid_by_logical_actor_evidence_test() {
  let exited =
    types.TraceEvent(
      "exit-old",
      "root",
      "app@host",
      logical_identity("<0.2.0>", "checkout-worker"),
      types.LocalInstant(100, 100),
      types.Exit(types.Tag("badmatch")),
      types.Exact,
    )
  let spawned =
    types.TraceEvent(
      "spawn-new",
      "root",
      "app@host",
      logical_identity("<0.1.0>", "shop-supervisor"),
      types.LocalInstant(130, 130),
      types.Spawn(
        types.ProcessRef("app@host", "<0.9.0>"),
        types.Mfa("checkout_worker", "start_link", 1),
      ),
      types.Exact,
    )
  let observed_new =
    types.TraceEvent(
      "new-ready",
      "root",
      "app@host",
      logical_identity("<0.9.0>", "checkout-worker"),
      types.LocalInstant(140, 140),
      types.Register("checkout_worker"),
      types.Exact,
    )

  diagnostics.restart_chains(
    [exited, spawned, observed_new],
    maximum_gap_ns: 100,
  )
  |> should.equal([
    diagnostics.Finding(
      kind: diagnostics.CrashChain,
      summary: "checkout-worker restarted with a new PID after 30ns",
      evidence: types.inferred(
        "logical_actor_restart_v2",
        "an exit and subsequent spawn converge on the same logical actor slot",
        [
          types.EvidenceEvent("exit-old"),
          types.EvidenceEvent("spawn-new"),
          types.EvidenceEvent("new-ready"),
          types.ObservedValue("gap_ns", "30"),
          types.AlgorithmSetting("maximum_gap_ns", "100"),
        ],
      ),
      event_ids: ["exit-old", "spawn-new", "new-ready"],
      value: diagnostics.TimeValue(types.ExactTime(30)),
    ),
  ])

  diagnostics.restart_chains([exited, spawned], maximum_gap_ns: 100)
  |> should.equal([])
}

pub fn dangling_call_is_not_asserted_for_an_unverified_capture_test() {
  let call = send("call", "<0.1.0>", "<0.2.0>", "call", 10, 100)
  let partial =
    types.CaptureOutcome(
      types.QuietPeriod(250),
      [types.MissingNode("other@host")],
      [types.NodeReceipt("app@host", 1, 1, 1)],
    )

  diagnostics.dangling_calls(
    [call],
    outcome: partial,
    now_ns: 1000,
    timeout_ns: 500,
  )
  |> should.equal([])
}

pub fn repeated_calls_are_left_unmatched_instead_of_fabricating_a_dangling_pair_test() {
  diagnostics.dangling_calls(
    [
      send("call-1", "<0.1.0>", "<0.2.0>", "call", 10, 100),
      send("call-2", "<0.1.0>", "<0.2.0>", "call", 11, 200),
    ],
    outcome: verified_outcome(),
    now_ns: 1000,
    timeout_ns: 500,
  )
  |> should.equal([])
}
