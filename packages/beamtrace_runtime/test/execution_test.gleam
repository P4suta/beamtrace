// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/cli
import beamtrace_runtime/execution
import gleam/option.{None}
import gleeunit/should

pub fn distribution_cookie_is_scoped_to_target_operations_test() {
  execution.plan(cli.Attach("app@host", cli.Web, None))
  |> should.equal(execution.TargetDistribution("app@host", None))
  execution.plan(cli.Capture(
    "app@host",
    cli.Mfa("api", "run", 0),
    None,
    "trace.beamtrace",
    None,
    1,
    types.Generic,
  ))
  |> should.equal(execution.TargetDistribution("app@host", None))

  execution.plan(cli.Serve) |> should.equal(execution.HubWithoutCookie)
  execution.plan(cli.Relay("https://hub", "once", None))
  |> should.equal(execution.OutboundRelayOnly("https://hub"))
}

pub fn offline_commands_never_request_distribution_or_network_test() {
  execution.plan(cli.Open("trace.beamtrace", cli.Web))
  |> should.equal(execution.OfflineFiles(["trace.beamtrace"]))
  execution.plan(cli.Compare("good.beamtrace", "bad.beamtrace"))
  |> should.equal(execution.OfflineFiles(["good.beamtrace", "bad.beamtrace"]))
  execution.plan(cli.Export("trace.beamtrace", cli.Jsonl))
  |> should.equal(execution.OfflineFiles(["trace.beamtrace"]))
}

pub fn record_owns_both_the_target_and_child_process_boundaries_test() {
  execution.plan(
    cli.Record(
      "app@host",
      cli.Mfa("m", "f", 0),
      None,
      "x.beamtrace",
      None,
      1,
      types.Generic,
      ["gleam", "test"],
    ),
  )
  |> should.equal(
    execution.RecordTargetAndChild("app@host", None, ["gleam", "test"]),
  )
}
