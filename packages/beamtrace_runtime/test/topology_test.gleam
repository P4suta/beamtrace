// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/topology
import gleam/option.{None, Some}
import gleeunit/should

pub fn supervision_spawn_and_link_graphs_remain_distinct_test() {
  let snapshots = [
    topology.ProcessSnapshot("sup", None, None, ["worker"]),
    topology.ProcessSnapshot("worker", Some("sup"), Some("starter"), ["sup"]),
  ]
  let graphs = topology.build(snapshots)

  graphs.supervision
  |> should.equal([
    topology.Edge("sup", "worker", types.Exact),
  ])
  graphs.spawn
  |> should.equal([
    topology.Edge("starter", "worker", types.Exact),
  ])
  graphs.links
  |> should.equal([
    topology.Edge("sup", "worker", types.Exact),
  ])
}
