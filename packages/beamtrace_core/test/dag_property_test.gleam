// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/dag
import beamtrace/types
import gleam/option.{None}
import qcheck

fn process(node: String, pid: String) -> types.ProcessIdentity {
  types.ProcessIdentity(
    physical: types.ProcessRef(node, pid),
    logical: None,
    evidence: [],
  )
}

fn event(
  id: String,
  at: Int,
  process: types.ProcessIdentity,
  kind: types.TraceEventKind,
) -> types.TraceEvent {
  types.TraceEvent(
    id: id,
    root_id: "root",
    node: process.physical.node,
    process: process,
    local_instant: types.LocalInstant(at + 1_000_001, at + 1_000_001),
    kind: kind,
    evidence: types.Exact,
  )
}

pub fn distributed_clock_offsets_preserve_causal_acyclicity_property_test() {
  let timestamp = qcheck.bounded_int(-1_000_000, 1_000_000)
  let offsets = qcheck.tuple3(timestamp, timestamp, timestamp)
  let config =
    qcheck.config(
      test_count: 2000,
      max_retries: 1,
      seed: qcheck.seed(20_260_823),
    )

  use offsets <- qcheck.run(config, offsets)
  let #(client_at, worker_at, leaf_at) = offsets
  let client = process("client@host", "<0.10.0>")
  let worker = process("worker@host", "<0.20.0>")
  let leaf = process("leaf@host", "<0.30.0>")

  let events = [
    event("root", client_at, client, types.Root(types.Mfa("api", "run", 0), [])),
    event(
      "send-worker",
      client_at + 1,
      client,
      types.Send(
        worker.physical,
        types.TagOnly("work"),
        types.SequenceSerial(40, 41),
      ),
    ),
    event(
      "receive-worker",
      worker_at,
      worker,
      types.Received(
        client.physical,
        types.TagOnly("work"),
        types.SequenceSerial(40, 41),
      ),
    ),
    event(
      "send-leaf",
      worker_at + 1,
      worker,
      types.Send(
        leaf.physical,
        types.TagOnly("work"),
        types.SequenceSerial(41, 42),
      ),
    ),
    event(
      "receive-leaf",
      leaf_at,
      leaf,
      types.Received(
        worker.physical,
        types.TagOnly("work"),
        types.SequenceSerial(41, 42),
      ),
    ),
  ]

  let assert Ok(graph) = dag.build(events)
  assert dag.is_acyclic(graph)
  assert graph.boundaries == []
}
