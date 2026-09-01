//// Deterministic, bounded online anomaly baselines for Live observations.
////
//// Detectors update only from supplied samples and report stated thresholds;
//// alerts are evidence-bearing diagnostics, not probabilities. Each observe
//// operation is O(configured metrics), has no I/O failure, and behaves the
//// same on Erlang and JavaScript.

import beamtrace/types
import gleam/float
import gleam/int
import gleam/list

/// A bounded live metric tracked by the online detector.
pub type MetricKind {
  Mailbox
  Memory
  Heap
  Reductions
  ProcessCount
  RestartCount
  DistributionQueue
}

/// A stable classification for an anomaly alert.
pub type AnomalyKind {
  MailboxGrowth
  MemoryGrowth
  HeapGrowth
  ReductionSpike
  ProcessLeak
  RestartStorm
  BusyDistributionPort
  LongGarbageCollection
  LongSchedule
  LargeHeap
}

/// An exact VM signal received directly from the runtime.
pub type VmSignal {
  LongGc
  LongScheduleSignal
  LargeHeapSignal
  BusyDistPort
}

/// An evidence-bearing anomaly observation and its opening time.
pub type Alert {
  Alert(
    kind: AnomalyKind,
    summary: String,
    evidence: types.Evidence,
    opened_at_ns: Int,
  )
}

/// The EWMA and hysteresis counters for one metric.
pub type Baseline {
  Baseline(
    metric: MetricKind,
    ewma: Float,
    initialized: Bool,
    high_samples: Int,
    low_samples: Int,
  )
}

/// Pure detector state. Its metric and alert lists remain bounded by `MetricKind`.
pub type Detector {
  Detector(
    alpha: Float,
    open_after: Int,
    close_after: Int,
    baselines: List(Baseline),
    active: List(Alert),
  )
}

/// Create an empty detector, clamping alpha to 0.01–1.0 and thresholds to at
/// least one sample. This is O(1), pure, and cannot fail.
pub fn new_detector(
  alpha alpha: Float,
  open_after open_after: Int,
  close_after close_after: Int,
) -> Detector {
  Detector(
    alpha: clamp(alpha, 0.01, 1.0),
    open_after: max_one(open_after),
    close_after: max_one(close_after),
    baselines: [],
    active: [],
  )
}

/// Incorporate one sample and deterministically open or close an alert.
/// Work is O(m + a) for the bounded metric and active-alert lists and cannot
/// fail; inferred alerts record the threshold inputs used.
pub fn observe(
  detector: Detector,
  metric: MetricKind,
  value: Float,
  observed_at_ns: Int,
) -> Detector {
  let baseline = find_baseline(detector.baselines, metric)
  let updated = update_baseline(baseline, value, detector.alpha)
  let should_open =
    updated.high_samples >= detector.open_after
    && !has_alert(detector.active, anomaly_kind(metric))
  let should_close =
    updated.low_samples >= detector.close_after
    && has_alert(detector.active, anomaly_kind(metric))

  let active = case should_open, should_close {
    True, _ -> [
      Alert(
        kind: anomaly_kind(metric),
        summary: summary(metric),
        evidence: types.inferred(
          "ewma_hysteresis_v2",
          "EWMA exceeded baseline with hysteresis",
          [
            types.ObservedValue("value", float.to_string(value)),
            types.ObservedValue("baseline", float.to_string(baseline.ewma)),
            types.AlgorithmSetting("alpha", float.to_string(detector.alpha)),
            types.AlgorithmSetting(
              "open_after",
              int.to_string(detector.open_after),
            ),
          ],
        ),
        opened_at_ns: observed_at_ns,
      ),
      ..detector.active
    ]
    _, True -> remove_alert(detector.active, anomaly_kind(metric))
    _, _ -> detector.active
  }

  Detector(
    ..detector,
    baselines: put_baseline(detector.baselines, updated),
    active: active,
  )
}

fn update_baseline(baseline: Baseline, value: Float, alpha: Float) -> Baseline {
  case baseline.initialized {
    False -> Baseline(..baseline, ewma: value, initialized: True)
    True -> {
      // Classify against the pre-update baseline so the spike cannot move its
      // own threshold. A floor avoids noise around zero-valued baselines.
      let high =
        value >. baseline.ewma *. 3.0 && value -. baseline.ewma >=. 10.0
      let low = value <=. baseline.ewma *. 1.5
      Baseline(
        ..baseline,
        ewma: alpha *. value +. { 1.0 -. alpha } *. baseline.ewma,
        high_samples: case high {
          True -> baseline.high_samples + 1
          False -> 0
        },
        low_samples: case low {
          True -> baseline.low_samples + 1
          False -> 0
        },
      )
    }
  }
}

fn find_baseline(baselines: List(Baseline), metric: MetricKind) -> Baseline {
  case baselines {
    [] -> Baseline(metric, 0.0, False, 0, 0)
    [baseline, ..rest] ->
      case baseline.metric == metric {
        True -> baseline
        False -> find_baseline(rest, metric)
      }
  }
}

fn put_baseline(
  baselines: List(Baseline),
  replacement: Baseline,
) -> List(Baseline) {
  case baselines {
    [] -> [replacement]
    [baseline, ..rest] if baseline.metric == replacement.metric -> [
      replacement,
      ..rest
    ]
    [baseline, ..rest] -> [baseline, ..put_baseline(rest, replacement)]
  }
}

fn has_alert(alerts: List(Alert), kind: AnomalyKind) -> Bool {
  list.any(alerts, fn(alert) { alert.kind == kind })
}

fn remove_alert(alerts: List(Alert), kind: AnomalyKind) -> List(Alert) {
  list.filter(alerts, fn(alert) { alert.kind != kind })
}

fn anomaly_kind(metric: MetricKind) -> AnomalyKind {
  case metric {
    Mailbox -> MailboxGrowth
    Memory -> MemoryGrowth
    Heap -> HeapGrowth
    Reductions -> ReductionSpike
    ProcessCount -> ProcessLeak
    RestartCount -> RestartStorm
    DistributionQueue -> BusyDistributionPort
  }
}

fn summary(metric: MetricKind) -> String {
  case metric {
    Mailbox -> "mailbox is growing above its baseline"
    Memory -> "process memory is growing above its baseline"
    Heap -> "heap is growing above its baseline"
    Reductions -> "reductions exceeded the process baseline"
    ProcessCount -> "process count indicates a possible leak"
    RestartCount -> "restart rate indicates a restart storm"
    DistributionQueue -> "distribution queue is persistently busy"
  }
}

/// Convert one runtime signal into an exact-evidence alert in O(1).
pub fn from_vm_signal(signal: VmSignal, value: Int) -> Alert {
  case signal {
    LongGc ->
      Alert(
        LongGarbageCollection,
        "long GC: " <> int.to_string(value) <> "us",
        types.Exact,
        0,
      )
    LongScheduleSignal ->
      Alert(
        LongSchedule,
        "long schedule: " <> int.to_string(value) <> "us",
        types.Exact,
        0,
      )
    LargeHeapSignal ->
      Alert(
        LargeHeap,
        "large heap: " <> int.to_string(value) <> " words",
        types.Exact,
        0,
      )
    BusyDistPort ->
      Alert(BusyDistributionPort, "busy distribution port", types.Exact, 0)
  }
}

fn clamp(value: Float, minimum: Float, maximum: Float) -> Float {
  case value <. minimum, value >. maximum {
    True, _ -> minimum
    _, True -> maximum
    _, _ -> value
  }
}

fn max_one(value: Int) -> Int {
  case value < 1 {
    True -> 1
    False -> value
  }
}
