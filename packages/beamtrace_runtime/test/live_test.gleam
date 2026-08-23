import beamtrace_runtime/live
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn split_sampling_covers_each_process_once_per_cycle_test() {
  let processes = ["p1", "p2", "p3", "p4", "p5", "p6", "p7"]
  let sampled =
    [0, 1, 2]
    |> list.flat_map(fn(tick) {
      live.sample_shard(processes, tick, shard_count: 3)
    })
    |> list.sort(string.compare)
  sampled |> should.equal(processes |> list.sort(string.compare))
}

pub fn deep_inspection_is_bounded_and_permission_checked_test() {
  let policy =
    live.DeepInspectionPolicy(
      max_mailbox_messages: 100,
      max_term_bytes: 65_536,
      timeout_ms: 250,
      allow_sys_status: True,
    )
  live.authorize_inspection(
    policy,
    live.InspectionRequest(101, 1000, False),
    has_permission: True,
  )
  |> should.equal(Error(live.MailboxTooLarge(101, 100)))

  live.authorize_inspection(
    policy,
    live.InspectionRequest(1, 1000, False),
    has_permission: False,
  )
  |> should.equal(Error(live.PermissionDenied))
}

pub fn sys_status_requires_explicit_policy_test() {
  let policy = live.DeepInspectionPolicy(100, 1000, 100, False)
  live.authorize_inspection(policy, live.InspectionRequest(1, 100, True), True)
  |> should.equal(Error(live.SysStatusDisabled))
}

pub fn otp27_uses_system_monitor_and_newer_otp_uses_isolated_trace_system_test() {
  live.signal_backend(27) |> should.equal(live.ErlangSystemMonitor)
  live.signal_backend(28) |> should.equal(live.IsolatedTraceSystem)
  live.signal_backend(29) |> should.equal(live.IsolatedTraceSystem)
}

pub fn process_sample_uses_stable_metadata_label_and_bounded_deltas_test() {
  let previous =
    live.normalize_sample(live.RawProcessSample(
      "app@host",
      "<0.42.0>",
      "orders",
      "orders_worker:init/1",
      2,
      10_000,
      100,
      200,
      300,
      2,
      "waiting",
      "gen_server:loop/7",
    ))
  let current =
    live.ProcessSample(
      ..previous,
      mailbox_len: 9,
      memory_bytes: 12_000,
      reductions: 175,
    )

  previous.label |> should.equal("orders")
  live.delta(previous, current)
  |> should.equal(Some(live.ProcessDelta(7, 2000, 75)))

  live.delta(previous, live.ProcessSample(..current, pid: "<0.99.0>"))
  |> should.equal(None)
}

pub fn sample_without_registered_name_falls_back_to_initial_call_test() {
  live.normalize_sample(live.RawProcessSample(
    "app@host",
    "<0.7.0>",
    "",
    "worker:start/0",
    0,
    1,
    2,
    3,
    4,
    0,
    "waiting",
    "worker:loop/0",
  ))
  |> fn(sample) { sample.label }
  |> should.equal("worker:start/0")
}
