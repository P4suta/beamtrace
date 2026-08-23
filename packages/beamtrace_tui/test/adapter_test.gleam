// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_tui/adapter
import beamtrace_tui/model
import gleam/option.{None, Some}
import gleeunit/should

pub fn canonical_trace_events_become_vertical_tui_rows_test() {
  let process =
    types.ProcessIdentity(
      physical: types.ProcessRef("app@host", "<0.42.0>"),
      logical: Some(types.LogicalActor("checkout", "checkout")),
      evidence: [],
    )
  let root =
    types.TraceEvent(
      "root",
      "root",
      "app@host",
      process,
      1000,
      types.Root(types.Mfa("shop", "checkout", 1), []),
      types.Exact,
    )
  let crashed =
    types.TraceEvent(
      "exit",
      "root",
      "app@host",
      process,
      3500,
      types.Exit(types.Tag("badmatch")),
      types.inferred("restart proximity", 0.92),
    )

  adapter.from_trace([root, crashed])
  |> should.equal([
    model.Event("root", "checkout", "call shop:checkout/1", "Exact", 0, False),
    model.Event(
      "exit",
      "checkout",
      "exit",
      "Inferred 0.92 · restart proximity",
      2,
      True,
    ),
  ])
}

pub fn physical_pid_is_used_only_when_no_logical_actor_exists_test() {
  let process =
    types.ProcessIdentity(
      physical: types.ProcessRef("app@host", "<0.9.0>"),
      logical: None,
      evidence: [],
    )
  let event =
    types.TraceEvent(
      "stop",
      "root",
      "app@host",
      process,
      10,
      types.Stop("complete"),
      types.Exact,
    )
  adapter.from_trace([event])
  |> should.equal([
    model.Event("stop", "<0.9.0>", "stop", "Exact", 0, False),
  ])
}
