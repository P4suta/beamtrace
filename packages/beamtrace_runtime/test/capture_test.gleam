import beamtrace/aql
import beamtrace/dag
import beamtrace/types
import beamtrace_runtime/capture
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

pub fn relay_events_become_exact_acyclic_trace_test() {
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
  result.completeness |> should.equal(types.Complete)
  let assert Ok(graph) = dag.build(result.events)
  dag.edge_between(graph, "send", "receive")
  |> should.equal(
    Some(types.CausalEdge(
      "send",
      "receive",
      types.SequentialMessage(7),
      types.Exact,
    )),
  )
}

pub fn truncated_capture_maps_to_exit_code_three_test() {
  let completeness = capture.parse_completeness("truncated:event_budget")
  completeness |> should.equal(types.Truncated("event_budget"))
  completeness |> capture.exit_code |> should.equal(3)
}

pub fn inferred_capture_preserves_reason_test() {
  capture.parse_completeness("inferred:system_tracer_occupied")
  |> should.equal(types.InferredCapture("system_tracer_occupied"))
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

pub fn comma_separated_partial_nodes_remain_explicit_test() {
  capture.parse_completeness("partial_node:a@host,b@host")
  |> should.equal(types.PartialNode(["a@host", "b@host"]))
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
  filtered.completeness |> should.equal(types.Complete)
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
