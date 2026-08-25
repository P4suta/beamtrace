import beamtrace/aql
import beamtrace/dag
import beamtrace/types
import beamtrace_runtime/capture
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn legacy_relay_serial_is_not_promoted_to_exact_causality_test() {
  let trigger = types.Mfa("shop", "checkout", 1)
  let raw = [
    capture.RawEvent(
      "root",
      "r1",
      "app@host",
      "<0.10.0>",
      1,
      "root",
      "",
      "",
      0,
      "root",
    ),
    capture.RawEvent(
      "send",
      "r1",
      "app@host",
      "<0.10.0>",
      2,
      "send",
      "app@host",
      "<0.20.0>",
      7,
      "call",
    ),
    capture.RawEvent(
      "receive",
      "r1",
      "app@host",
      "<0.20.0>",
      3,
      "receive",
      "app@host",
      "<0.10.0>",
      7,
      "call",
    ),
  ]
  let result = capture.normalize(raw, "complete", trigger)
  result.outcome.end |> should.equal(types.LegacyUnknown)
  types.delivery_verified(result.outcome) |> should.be_false()
  let assert Ok(graph) = dag.build(result.events)
  dag.edge_between(graph, "send", "receive")
  |> should.equal(
    Some(types.CausalEdge(
      "send",
      "receive",
      types.SequentialMessage(types.LegacySerial(7)),
      types.inferred(
        "legacy_unique_serial",
        "v1 retained only the current seq_trace serial",
        [
          types.EvidenceEvent("send"),
          types.EvidenceEvent("receive"),
        ],
      ),
    )),
  )
}

pub fn relay_term_shapes_survive_normalization_without_scalar_disclosure_test() {
  let metadata = capture.RawProcessMetadata("", "", "", "", -1, [], "")
  let raw = [
    capture.RawEventWithTerm(
      "root",
      "r1",
      "app@host",
      "<0.1.0>",
      1,
      "root",
      "",
      "",
      0,
      "root",
      metadata,
      capture.RawList(1, [capture.RawAtom("order")]),
    ),
    capture.RawEventWithTerm(
      "send",
      "r1",
      "app@host",
      "<0.1.0>",
      2,
      "send",
      "app@host",
      "<0.2.0>",
      7,
      "call",
      metadata,
      capture.RawTuple(3, [
        capture.RawAtom("$gen_call"),
        capture.RawScalar("reference", "", "salted-reference"),
        capture.RawTuple(2, [
          capture.RawAtom("checkout"),
          capture.RawScalar("integer", "", "salted-integer"),
        ]),
      ]),
    ),
  ]

  let result = capture.normalize(raw, "complete", types.Mfa("shop", "run", 1))
  let assert [root, sent] = result.events
  root.kind
  |> should.equal(
    types.Root(types.Mfa("shop", "run", 1), [
      types.Atom("order"),
    ]),
  )
  sent.kind
  |> should.equal(types.Send(
    types.ProcessRef("app@host", "<0.2.0>"),
    types.Constructor("$gen_call", [
      types.Scalar("reference", None, Some("salted-reference")),
      types.Constructor("checkout", [
        types.Scalar("integer", None, Some("salted-integer")),
      ]),
    ]),
    types.LegacySerial(7),
  ))
}

pub fn truncated_capture_maps_to_exit_code_three_test() {
  let result =
    capture.normalize([], "truncated:event_budget", types.Mfa("m", "f", 0))
  result.outcome.end |> should.equal(types.BudgetReached("event_budget"))
  result.outcome |> capture.exit_code |> should.equal(3)
}

pub fn occupied_system_tracer_is_a_safety_refusal_with_live_fallback_test() {
  capture.failure_exit_code("system_tracer_occupied") |> should.equal(4)
  capture.failure_guidance("system_tracer_occupied")
  |> string.contains("Live")
  |> should.be_true()
  capture.failure_exit_code("nodedown") |> should.equal(2)
}

pub fn inferred_capture_preserves_reason_test() {
  let result =
    capture.normalize(
      [],
      "inferred:system_tracer_occupied",
      types.Mfa("m", "f", 0),
    )
  result.outcome.issues
  |> should.equal([types.LegacyUnverified("system_tracer_occupied")])
}

pub fn capture_spec_compiles_agent_filter_and_preserves_only_the_residual_test() {
  let spec =
    types.CaptureSpec(
      ..types.default_capture_spec(types.Mfa("shop", "checkout", 1)),
      nodes: ["one@host", "two@host"],
      where_aql: Some("arg.0.tag == allowed and process.label == checkout"),
      budget: types.TraceBudget(
        max_events: 500,
        max_bytes: 100_000,
        max_duration_ms: 2500,
        drain_timeout_ms: 10_000,
        max_agent_mailbox: 50,
        max_roots: 3,
      ),
      preset: types.GenServer,
    )
  let assert Ok(prepared) = capture.prepare(spec)

  prepared.predicate
  |> should.equal(aql.AgentArgTag(0, aql.AgentEqual, "allowed"))
  prepared.residual
  |> should.equal(
    Some(aql.Compare("process.label", aql.Equal, aql.StringValue("checkout"))),
  )
  prepared.spec |> should.equal(spec)
}

pub fn impossible_or_unbounded_capture_spec_fails_before_distribution_test() {
  let impossible =
    types.CaptureSpec(
      ..types.default_capture_spec(types.Mfa("shop", "checkout", 1)),
      nodes: ["app@host"],
      where_aql: Some("module == other"),
    )
  capture.prepare(impossible)
  |> should.equal(Error("capture_filter_cannot_match_trigger"))

  let unbounded =
    types.CaptureSpec(
      ..impossible,
      where_aql: None,
      budget: types.TraceBudget(0, 1, 1, 10_000, 1, 1),
    )
  capture.prepare(unbounded)
  |> should.equal(Error("invalid_event_budget"))
}

pub fn unknown_wire_event_becomes_gap_not_fake_message_test() {
  let raw = [
    capture.RawEvent(
      "unknown",
      "r1",
      "app@host",
      "<0.1.0>",
      1,
      "future_kind",
      "",
      "",
      0,
      "message",
    ),
  ]
  let result = capture.normalize(raw, "gapped:1", types.Mfa("m", "f", 0))
  let assert [event] = result.events
  event.kind |> should.equal(types.Gap(1, "unknown relay event: future_kind"))
  event.process.logical |> should.equal(None)
}

pub fn relay_process_metadata_resolves_a_stable_logical_actor_test() {
  let raw = [
    capture.RawEventWithMetadata(
      "registered",
      "r1",
      "app@host",
      "<0.2.0>",
      3,
      "register",
      "",
      "",
      0,
      "checkout_worker",
      capture.RawProcessMetadata(
        registered_name: "checkout_worker",
        process_label: "checkout-slot",
        initial_module: "shop_worker",
        initial_function: "init",
        initial_arity: 1,
        ancestors: ["checkout_sup", "shop_sup"],
        supervisor_child_id: "checkout-child",
      ),
    ),
  ]

  let result = capture.normalize(raw, "complete", types.Mfa("root", "run", 0))
  let assert [event] = result.events

  event.process.logical
  |> should.equal(
    Some(types.LogicalActor(
      "checkout_sup/shop_sup/checkout-slot",
      "checkout-slot",
    )),
  )
  event.process.evidence
  |> should.equal([
    types.RegisteredName("checkout_worker"),
    types.ProcessLabel("checkout-slot"),
    types.InitialCall(types.Mfa("shop_worker", "init", 1)),
    types.Ancestor("checkout_sup"),
    types.Ancestor("shop_sup"),
    types.SupervisorChildId("checkout-child"),
  ])
}

pub fn observed_identity_is_propagated_to_every_event_for_the_physical_pid_test() {
  let raw = [
    capture.RawEventWithMetadata(
      "registered",
      "r1",
      "app@host",
      "<0.2.0>",
      3,
      "register",
      "",
      "",
      0,
      "checkout_worker",
      capture.RawProcessMetadata(
        registered_name: "checkout_worker",
        process_label: "",
        initial_module: "",
        initial_function: "",
        initial_arity: -1,
        ancestors: [],
        supervisor_child_id: "",
      ),
    ),
    capture.RawEvent(
      "exited",
      "r1",
      "app@host",
      "<0.2.0>",
      4,
      "exit",
      "",
      "",
      0,
      "spawn_done",
    ),
  ]

  let result = capture.normalize(raw, "complete", types.Mfa("root", "run", 0))
  let assert [registered, exited] = result.events

  registered.process.logical
  |> should.equal(
    Some(types.LogicalActor("checkout_worker", "checkout_worker")),
  )
  exited.process |> should.equal(registered.process)
}

pub fn process_trace_events_preserve_spawn_exit_register_and_link_semantics_test() {
  let raw = [
    capture.RawEvent(
      "spawn",
      "r1",
      "app@host",
      "<0.1.0>",
      1,
      "spawn",
      "app@host",
      "<0.2.0>",
      0,
      "shop_worker:start/1",
    ),
    capture.RawEvent(
      "link",
      "r1",
      "app@host",
      "<0.1.0>",
      2,
      "link",
      "app@host",
      "<0.2.0>",
      0,
      "link",
    ),
    capture.RawEvent(
      "register",
      "r1",
      "app@host",
      "<0.2.0>",
      3,
      "register",
      "",
      "",
      0,
      "shop_worker",
    ),
    capture.RawEvent(
      "exit",
      "r1",
      "app@host",
      "<0.2.0>",
      4,
      "exit",
      "",
      "",
      0,
      "spawn_done",
    ),
  ]
  let result = capture.normalize(raw, "complete", types.Mfa("root", "run", 0))
  let child = types.ProcessRef("app@host", "<0.2.0>")
  result.events
  |> list.map(fn(event) { event.kind })
  |> should.equal([
    types.Spawn(child, types.Mfa("shop_worker", "start", 1)),
    types.Link(child),
    types.Register("shop_worker"),
    types.Exit(types.Tag("spawn_done")),
  ])
}

pub fn distributed_capture_requires_at_least_one_root_node_test() {
  capture.distributed(
    [],
    "cookie",
    types.Mfa("shop", "checkout", 1),
    1000,
    capture.default_budget(),
  )
  |> should.equal(Error("capture_requires_at_least_one_node"))
}

pub fn legacy_partial_nodes_remain_explicitly_unverified_test() {
  let result =
    capture.normalize([], "partial_node:a@host,b@host", types.Mfa("m", "f", 0))
  result.outcome.issues
  |> should.equal([
    types.LegacyUnverified(
      "v1 reported partial nodes without receipts: a@host,b@host",
    ),
  ])
}

pub fn aql_match_keeps_the_entire_matching_root_chain_test() {
  let trigger = types.Mfa("shop", "checkout", 1)
  let raw = [
    capture.RawEvent(
      "root-1",
      "r1",
      "app@host",
      "<0.1.0>",
      1,
      "root",
      "",
      "",
      0,
      "root",
    ),
    capture.RawEvent(
      "send-1",
      "r1",
      "app@host",
      "<0.1.0>",
      2,
      "send",
      "app@host",
      "<0.2.0>",
      1,
      "call",
    ),
    capture.RawEvent(
      "root-2",
      "r2",
      "app@host",
      "<0.3.0>",
      3,
      "root",
      "",
      "",
      0,
      "root",
    ),
    capture.RawEvent(
      "send-2",
      "r2",
      "app@host",
      "<0.3.0>",
      4,
      "send",
      "app@host",
      "<0.4.0>",
      2,
      "cast",
    ),
  ]
  let result = capture.normalize(raw, "complete", trigger)
  let assert Ok(query) = aql.parse("message.tag == call")
  let filtered = capture.filter_roots(result, query, trigger)

  filtered.events
  |> list.map(fn(event) { event.id })
  |> should.equal(["root-1", "send-1"])
  filtered.outcome |> should.equal(result.outcome)
}

pub fn duplicate_agent_labels_are_split_into_distinct_causal_roots_test() {
  let trigger = types.Mfa("shop", "checkout", 0)
  let result =
    capture.normalize(
      [
        capture.RawEvent(
          "root-a",
          "session-label",
          "app@host",
          "<0.1.0>",
          1,
          "root",
          "",
          "",
          0,
          "root",
        ),
        capture.RawEvent(
          "send-a",
          "session-label",
          "app@host",
          "<0.1.0>",
          2,
          "send",
          "app@host",
          "<0.2.0>",
          1,
          "call",
        ),
        capture.RawEvent(
          "root-b",
          "session-label",
          "app@host",
          "<0.3.0>",
          3,
          "root",
          "",
          "",
          0,
          "root",
        ),
        capture.RawEvent(
          "send-b",
          "session-label",
          "app@host",
          "<0.3.0>",
          4,
          "send",
          "app@host",
          "<0.4.0>",
          1,
          "cast",
        ),
      ],
      "complete",
      trigger,
    )

  result.events
  |> list.map(fn(event) { #(event.id, event.root_id, event.evidence) })
  |> should.equal([
    #("root-a", "root-a", types.Exact),
    #("send-a", "root-a", types.Exact),
    #("root-b", "root-b", types.Exact),
    #("send-b", "root-b", types.Exact),
  ])
}

pub fn duplicate_root_attribution_uses_exact_graph_not_arrival_order_test() {
  let trigger = types.Mfa("shop", "checkout", 0)
  let result =
    capture.normalize_v2(
      [
        v2_event("received-a", "<0.9.0>", 1, "receive", "<0.1.0>", 10, 11),
        v2_event("root-b", "<0.2.0>", 0, "root", "", 0, 0),
        v2_event("send-a", "<0.1.0>", 1, "send", "<0.9.0>", 10, 11),
        v2_event("root-a", "<0.1.0>", 0, "root", "", 0, 0),
      ],
      capture.RawOutcome("quiet_period", "250", [], []),
      types.empty_calibration(),
      trigger,
    )
  let assert Ok(received) =
    list.find(result.events, fn(event) { event.id == "received-a" })
  received.root_id |> should.equal("root-a")
  received.evidence |> should.equal(types.Exact)
}

pub fn event_reachable_from_multiple_roots_remains_explicitly_ambiguous_test() {
  let trigger = types.Mfa("shop", "checkout", 0)
  let result =
    capture.normalize_v2(
      [
        v2_event("root-a", "<0.1.0>", 0, "root", "", 0, 0),
        v2_event("send-a", "<0.1.0>", 1, "send", "<0.9.0>", 10, 11),
        v2_event("received-a", "<0.9.0>", 1, "receive", "<0.1.0>", 10, 11),
        v2_event("root-b", "<0.2.0>", 0, "root", "", 0, 0),
        v2_event("send-b", "<0.2.0>", 1, "send", "<0.9.0>", 20, 21),
        v2_event("received-b", "<0.9.0>", 2, "receive", "<0.2.0>", 20, 21),
      ],
      capture.RawOutcome("quiet_period", "250", [], []),
      types.empty_calibration(),
      trigger,
    )
  let assert Ok(received) =
    list.find(result.events, fn(event) { event.id == "received-b" })
  received.root_id |> should.equal("ambiguous:session-label")
  let assert types.Inferred(inference) = received.evidence
  inference.method |> should.equal("exact_graph_root_reachability")
  inference.inputs
  |> list.contains(types.AlgorithmSetting("edge_policy", "Exact only"))
  |> should.be_true()
}

fn v2_event(
  id: String,
  process: String,
  order: Int,
  kind: String,
  peer: String,
  previous: Int,
  current: Int,
) -> capture.RawEvent {
  capture.RawEventV2(
    id: id,
    root_id: "session-label",
    node: "app@host",
    process_pid: process,
    local_offset_ns: order * 10,
    local_order: order,
    kind: kind,
    peer_node: case peer {
      "" -> ""
      _ -> "app@host"
    },
    peer_pid: peer,
    previous_serial: previous,
    current_serial: current,
    semantic: kind,
    metadata: capture.RawProcessMetadata("", "", "", "", -1, [], ""),
    term: capture.RawAtom(kind),
  )
}

pub fn aql_can_match_trigger_mfa_without_splitting_its_chain_test() {
  let trigger = types.Mfa("shop", "checkout", 1)
  let result =
    capture.normalize(
      [
        capture.RawEvent(
          "root",
          "r1",
          "app@host",
          "<0.1.0>",
          1,
          "root",
          "",
          "",
          0,
          "root",
        ),
        capture.RawEvent(
          "receive",
          "r1",
          "app@host",
          "<0.2.0>",
          2,
          "receive",
          "app@host",
          "<0.1.0>",
          3,
          "reply",
        ),
      ],
      "complete",
      trigger,
    )
  let assert Ok(query) = aql.parse("mfa == \"shop:checkout/1\"")

  capture.filter_roots(result, query, trigger).events
  |> list.length
  |> should.equal(2)
}

pub fn residual_aql_can_match_root_argument_shape_and_logical_process_test() {
  let metadata =
    capture.RawProcessMetadata("", "checkout", "", "", -1, [], "slot")
  let result =
    capture.normalize(
      [
        capture.RawEventWithTerm(
          "root",
          "r1",
          "app@host",
          "<0.1.0>",
          1,
          "root",
          "",
          "",
          0,
          "root",
          metadata,
          capture.RawList(1, [
            capture.RawTuple(2, [
              capture.RawAtom("order"),
              capture.RawScalar("integer", "", "fingerprint"),
            ]),
          ]),
        ),
        capture.RawEvent(
          "stop",
          "r1",
          "app@host",
          "<0.1.0>",
          2,
          "stop",
          "",
          "",
          0,
          "complete",
        ),
      ],
      "complete",
      types.Mfa("shop", "run", 1),
    )
  let assert Ok(query) =
    aql.parse(
      "process.label == checkout and arg.0.tag == order and arg.0.type == tuple",
    )

  capture.filter_roots(result, query, types.Mfa("shop", "run", 1)).events
  |> list.map(fn(event) { event.id })
  |> should.equal(["root", "stop"])
}
