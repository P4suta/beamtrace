import beamtrace/anomaly
import beamtrace/types
import beamtrace_runtime/topology
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type RawProcessSample {
  RawProcessSample(
    node: String,
    pid: String,
    registered_name: String,
    process_label: String,
    initial_call: String,
    mailbox_len: Int,
    memory_bytes: Int,
    reductions: Int,
    heap_words: Int,
    total_heap_words: Int,
    link_count: Int,
    status: String,
    current_function: String,
    links: List(String),
    ancestors: List(String),
  )
}

pub type ProcessSample {
  ProcessSample(
    node: String,
    pid: String,
    label: String,
    registered_name: String,
    process_label: String,
    initial_call: String,
    mailbox_len: Int,
    memory_bytes: Int,
    reductions: Int,
    heap_words: Int,
    total_heap_words: Int,
    link_count: Int,
    status: String,
    current_function: String,
    links: List(String),
    ancestors: List(String),
  )
}

pub type ProcessDelta {
  ProcessDelta(mailbox_growth: Int, memory_growth: Int, reductions_used: Int)
}

pub type LiveFinding {
  LiveFinding(
    pid: String,
    label: String,
    kind: String,
    summary: String,
    evidence: types.Evidence,
  )
}

pub fn normalize_sample(raw: RawProcessSample) -> ProcessSample {
  let label = case raw.process_label, raw.registered_name, raw.initial_call {
    process_label, _, _ if process_label != "" -> process_label
    "", registered_name, _ if registered_name != "" -> registered_name
    "", "", initial_call if initial_call != "" -> initial_call
    _, _, _ -> raw.pid
  }
  ProcessSample(
    node: raw.node,
    pid: raw.pid,
    label: label,
    registered_name: raw.registered_name,
    process_label: raw.process_label,
    initial_call: raw.initial_call,
    mailbox_len: raw.mailbox_len,
    memory_bytes: raw.memory_bytes,
    reductions: raw.reductions,
    heap_words: raw.heap_words,
    total_heap_words: raw.total_heap_words,
    link_count: raw.link_count,
    status: raw.status,
    current_function: raw.current_function,
    links: raw.links,
    ancestors: raw.ancestors,
  )
}

pub fn analyze(
  previous: List(ProcessSample),
  current: List(ProcessSample),
) -> List(LiveFinding) {
  current
  |> list.flat_map(fn(sample) {
    case find_sample(previous, sample.node, sample.pid) {
      Error(_) -> []
      Ok(before) -> sample_findings(before, sample)
    }
  })
}

pub fn topology_graphs(samples: List(ProcessSample)) -> topology.Graphs {
  samples
  |> list.map(fn(sample) {
    let supervisor = case sample.ancestors {
      [parent, ..] ->
        Some(#(
          parent,
          types.inferred("proc_lib_ancestor_v1", "proc_lib ancestor metadata", [
            types.ObservedValue("process", sample.pid),
            types.ObservedValue("ancestor", parent),
          ]),
        ))
      [] -> None
    }
    topology.ProcessSnapshot(
      id: sample.pid,
      supervisor_parent: supervisor,
      spawn_parent: None,
      links: sample.links,
    )
  })
  |> topology.build
}

fn sample_findings(
  previous: ProcessSample,
  current: ProcessSample,
) -> List(LiveFinding) {
  let detector =
    anomaly.new_detector(alpha: 0.2, open_after: 1, close_after: 2)
    |> anomaly.observe(anomaly.Mailbox, int.to_float(previous.mailbox_len), 0)
    |> anomaly.observe(anomaly.Memory, int.to_float(previous.memory_bytes), 0)
    |> anomaly.observe(anomaly.Heap, int.to_float(previous.total_heap_words), 0)
    |> anomaly.observe(anomaly.Reductions, int.to_float(previous.reductions), 0)
    |> anomaly.observe(anomaly.Mailbox, int.to_float(current.mailbox_len), 1)
    |> anomaly.observe(anomaly.Memory, int.to_float(current.memory_bytes), 1)
    |> anomaly.observe(anomaly.Heap, int.to_float(current.total_heap_words), 1)
    |> anomaly.observe(anomaly.Reductions, int.to_float(current.reductions), 1)

  list.map(detector.active, fn(alert) {
    LiveFinding(
      pid: current.pid,
      label: current.label,
      kind: anomaly_name(alert.kind),
      summary: alert.summary,
      evidence: alert.evidence,
    )
  })
}

fn find_sample(
  samples: List(ProcessSample),
  node: String,
  pid: String,
) -> Result(ProcessSample, Nil) {
  case samples {
    [] -> Error(Nil)
    [sample, ..rest] ->
      case sample.node == node && sample.pid == pid {
        True -> Ok(sample)
        False -> find_sample(rest, node, pid)
      }
  }
}

fn anomaly_name(kind: anomaly.AnomalyKind) -> String {
  case kind {
    anomaly.MailboxGrowth -> "mailbox_growth"
    anomaly.MemoryGrowth -> "memory_growth"
    anomaly.HeapGrowth -> "heap_growth"
    anomaly.ReductionSpike -> "reduction_spike"
    anomaly.ProcessLeak -> "process_leak"
    anomaly.RestartStorm -> "restart_storm"
    anomaly.BusyDistributionPort -> "busy_distribution_port"
    anomaly.LongGarbageCollection -> "long_gc"
    anomaly.LongSchedule -> "long_schedule"
    anomaly.LargeHeap -> "large_heap"
  }
}

pub fn delta(
  previous: ProcessSample,
  current: ProcessSample,
) -> Option(ProcessDelta) {
  case previous.node == current.node && previous.pid == current.pid {
    False -> None
    True ->
      Some(ProcessDelta(
        mailbox_growth: current.mailbox_len - previous.mailbox_len,
        memory_growth: current.memory_bytes - previous.memory_bytes,
        reductions_used: current.reductions - previous.reductions,
      ))
  }
}

pub fn remote_sample(
  node: String,
  cookie: String,
  offset: Int,
  limit: Int,
) -> Result(#(List(ProcessSample), Int), String) {
  case sample_remote(node, cookie, offset, limit) {
    Error(error) -> Error(error)
    Ok(#(samples, next_offset)) ->
      Ok(#(list.map(samples, normalize_sample), next_offset))
  }
}

@external(erlang, "beamtrace_capture_ffi", "sample_remote")
fn sample_remote(
  node: String,
  cookie: String,
  offset: Int,
  limit: Int,
) -> Result(#(List(RawProcessSample), Int), String)

pub type SignalBackend {
  ErlangSystemMonitor
  IsolatedTraceSystem
}

/// `trace:system/3` is available from OTP 28. OTP 27 remains supported via
/// the older system-monitor signals, still without enabling all-message trace.
pub fn signal_backend(otp_major: Int) -> SignalBackend {
  case otp_major >= 28 {
    True -> IsolatedTraceSystem
    False -> ErlangSystemMonitor
  }
}

pub type DeepInspectionPolicy {
  DeepInspectionPolicy(
    max_mailbox_messages: Int,
    max_term_bytes: Int,
    timeout_ms: Int,
    allow_sys_status: Bool,
  )
}

pub type InspectionRequest {
  InspectionRequest(
    mailbox_messages: Int,
    estimated_term_bytes: Int,
    wants_sys_status: Bool,
  )
}

pub type InspectionError {
  PermissionDenied
  MailboxTooLarge(actual: Int, maximum: Int)
  TermBudgetExceeded(actual: Int, maximum: Int)
  InvalidTimeout
  SysStatusDisabled
}

pub fn sample_shard(
  processes: List(a),
  tick: Int,
  shard_count shard_count: Int,
) -> List(a) {
  let shard_count = case shard_count < 1 {
    True -> 1
    False -> shard_count
  }
  let assert Ok(target) = int.modulo(tick, by: shard_count)
  sample_at(processes, target, shard_count, 0, []) |> list.reverse
}

fn sample_at(
  processes: List(a),
  target: Int,
  shard_count: Int,
  index: Int,
  accumulator: List(a),
) -> List(a) {
  case processes {
    [] -> accumulator
    [process, ..rest] -> {
      let assert Ok(bucket) = int.modulo(index, by: shard_count)
      let accumulator = case bucket == target {
        True -> [process, ..accumulator]
        False -> accumulator
      }
      sample_at(rest, target, shard_count, index + 1, accumulator)
    }
  }
}

pub fn authorize_inspection(
  policy: DeepInspectionPolicy,
  request: InspectionRequest,
  has_permission has_permission: Bool,
) -> Result(Nil, InspectionError) {
  case
    has_permission,
    request.mailbox_messages > policy.max_mailbox_messages,
    request.estimated_term_bytes > policy.max_term_bytes,
    policy.timeout_ms > 0,
    request.wants_sys_status && !policy.allow_sys_status
  {
    False, _, _, _, _ -> Error(PermissionDenied)
    _, True, _, _, _ ->
      Error(MailboxTooLarge(
        request.mailbox_messages,
        policy.max_mailbox_messages,
      ))
    _, _, True, _, _ ->
      Error(TermBudgetExceeded(
        request.estimated_term_bytes,
        policy.max_term_bytes,
      ))
    _, _, _, False, _ -> Error(InvalidTimeout)
    _, _, _, _, True -> Error(SysStatusDisabled)
    _, _, _, True, False -> Ok(Nil)
  }
}
