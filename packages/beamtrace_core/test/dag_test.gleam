import beamtrace/dag
import beamtrace/types
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn process(
  node: String,
  pid: String,
  logical: String,
) -> types.ProcessIdentity {
  types.ProcessIdentity(
    physical: types.ProcessRef(node, pid),
    logical: Some(types.LogicalActor(logical, logical)),
    evidence: [types.RegisteredName(logical)],
  )
}

fn event(
  id: String,
  at: Int,
  process: types.ProcessIdentity,
  kind: types.TraceEventKind,
) {
  types.TraceEvent(
    id: id,
    root_id: "root-1",
    node: process.physical.node,
    process: process,
    local_instant: types.LocalInstant(at, at),
    kind: kind,
    evidence: types.Exact,
  )
}

pub fn sequential_serial_creates_exact_causal_edge_test() {
  let client = process("one@host", "<0.10.0>", "client")
  let worker = process("one@host", "<0.20.0>", "worker")
  let events = [
    event("root", 1, client, types.Root(types.Mfa("api", "run", 0), [])),
    event(
      "send",
      2,
      client,
      types.Send(
        worker.physical,
        types.TagOnly("work"),
        types.SequenceSerial(40, 41),
      ),
    ),
    event(
      "recv",
      3,
      worker,
      types.Received(
        client.physical,
        types.TagOnly("work"),
        types.SequenceSerial(40, 41),
      ),
    ),
  ]

  let assert Ok(graph) = dag.build(events)
  dag.edge_between(graph, "send", "recv")
  |> should.equal(
    Some(types.CausalEdge(
      from: "send",
      to: "recv",
      kind: types.SequentialMessage(types.SequenceSerial(40, 41)),
      evidence: types.Exact,
    )),
  )
  graph.boundaries |> should.equal([])
  dag.is_acyclic(graph) |> should.be_true()
}

pub fn distributed_clock_skew_does_not_break_serial_causality_test() {
  let client = process("west@host", "<0.10.0>", "client")
  let worker = process("east@host", "<0.20.0>", "worker")
  // The receive has a lower node-local timestamp and appears first. Cross-node
  // wall clocks never determine causality; the seq_trace serial does.
  let events = [
    event(
      "recv",
      10,
      worker,
      types.Received(
        client.physical,
        types.TagOnly("work"),
        types.SequenceSerial(76, 77),
      ),
    ),
    event(
      "send",
      20,
      client,
      types.Send(
        worker.physical,
        types.TagOnly("work"),
        types.SequenceSerial(76, 77),
      ),
    ),
  ]

  let assert Ok(graph) = dag.build(events)
  dag.edge_between(graph, "send", "recv")
  |> should.equal(
    Some(types.CausalEdge(
      from: "send",
      to: "recv",
      kind: types.SequentialMessage(types.SequenceSerial(76, 77)),
      evidence: types.Exact,
    )),
  )
  graph.boundaries |> should.equal([])
  dag.is_acyclic(graph) |> should.be_true()
}

pub fn trace_timestamp_precedes_mailbox_delivery_order_test() {
  let parent = process("one@host", "<0.10.0>", "parent")
  let child = process("one@host", "<0.20.0>", "child")
  let serial = types.SequenceSerial(40, 41)
  // Messages emitted by the seq_trace system tracer and the isolated trace
  // session can reach the collector mailbox in a different order. The
  // monotonic timestamp still records the causal order shown by offset_ns.
  let events = [
    types.TraceEvent(
      ..event("root", 1, parent, types.Root(types.Mfa("api", "run", 0), [])),
      local_instant: types.LocalInstant(1, 0),
    ),
    types.TraceEvent(
      ..event(
        "parent-receive",
        5,
        parent,
        types.Received(child.physical, types.TagOnly("ready"), serial),
      ),
      local_instant: types.LocalInstant(5, 1),
    ),
    types.TraceEvent(
      ..event(
        "spawn",
        2,
        parent,
        types.Spawn(child.physical, types.Mfa("worker", "start", 0)),
      ),
      local_instant: types.LocalInstant(2, 4),
    ),
    types.TraceEvent(
      ..event("child-first", 3, child, types.SystemSignal("spawned", 0)),
      local_instant: types.LocalInstant(3, 2),
    ),
    types.TraceEvent(
      ..event(
        "child-send",
        4,
        child,
        types.Send(parent.physical, types.TagOnly("ready"), serial),
      ),
      local_instant: types.LocalInstant(4, 3),
    ),
  ]

  let assert Ok(graph) = dag.build(events)
  dag.edge_between(graph, "spawn", "child-first")
  |> should.not_equal(None)
  dag.edge_between(graph, "child-send", "parent-receive")
  |> should.not_equal(None)
  dag.is_acyclic(graph) |> should.be_true()
}

pub fn missing_receive_becomes_boundary_not_invented_edge_test() {
  let client = process("one@host", "<0.10.0>", "client")
  let absent = types.ProcessRef("down@host", "<0.40.0>")
  let events = [
    event(
      "send",
      2,
      client,
      types.Send(absent, types.TagOnly("work"), types.SequenceSerial(98, 99)),
    ),
  ]

  let assert Ok(graph) = dag.build(events)
  graph.boundaries
  |> should.equal([
    types.Boundary("send", types.ExternalBoundary, "receive was not observed"),
  ])
  graph.edges |> should.equal([])
}

pub fn duplicate_ids_are_rejected_test() {
  let client = process("one@host", "<0.10.0>", "client")
  let events = [
    event("same", 1, client, types.Stop("done")),
    event("same", 2, client, types.Stop("done")),
  ]

  dag.build(events) |> should.equal(Error(dag.DuplicateEventId("same")))
}

pub fn dag_error_messages_are_stable_test() {
  dag.error_message(dag.DuplicateEventId("a"))
  |> should.equal("duplicate event id 'a'")
  dag.error_message(dag.CycleDetected)
  |> should.equal("the causal graph contains a cycle")
}
