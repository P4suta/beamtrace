import beamtrace/dag
import beamtrace/types
import gleam/option.{Some}
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
        types.Tag("work"),
        types.SequenceSerial(40, 41),
      ),
    ),
    event(
      "recv",
      3,
      worker,
      types.Received(
        client.physical,
        types.Tag("work"),
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
        types.Tag("work"),
        types.SequenceSerial(76, 77),
      ),
    ),
    event(
      "send",
      20,
      client,
      types.Send(
        worker.physical,
        types.Tag("work"),
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

pub fn missing_receive_becomes_boundary_not_invented_edge_test() {
  let client = process("one@host", "<0.10.0>", "client")
  let absent = types.ProcessRef("down@host", "<0.40.0>")
  let events = [
    event(
      "send",
      2,
      client,
      types.Send(absent, types.Tag("work"), types.SequenceSerial(98, 99)),
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
