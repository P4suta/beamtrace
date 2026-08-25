import gleam/option.{type Option, None}

/// Every observation and inference in BeamTrace carries its epistemic status.
/// Inferences are reproducible claims, not probabilities: the method, reason,
/// evidence events, observations, and settings are all retained.
pub type InferenceInput {
  EvidenceEvent(id: String)
  ObservedValue(name: String, value: String)
  AlgorithmSetting(name: String, value: String)
}

pub type Inference {
  Inference(method: String, reason: String, inputs: List(InferenceInput))
}

pub type Evidence {
  Exact
  Inferred(inference: Inference)
}

pub fn inferred(
  method: String,
  reason: String,
  inputs: List(InferenceInput),
) -> Evidence {
  Inferred(Inference(method, reason, inputs))
}

/// Node-local time is stored relative to a capture-local node origin. `order`
/// is a strict local tie-breaker and is safe to expose to JavaScript.
pub type LocalInstant {
  LocalInstant(offset_ns: Int, order: Int)
}

pub type SequenceSerial {
  SequenceSerial(previous: Int, current: Int)
  LegacySerial(current: Int)
}

pub type ObservationEnd {
  QuietPeriod(quiet_ms: Int)
  TimeWindow(window_ms: Int)
  UserStopped
  BudgetReached(budget: String)
  AgentFailure(node: String, reason: String)
  LegacyUnknown
}

pub type CaptureIssue {
  DroppedEvents(node: String, count: Int)
  MissingNode(node: String)
  BatchSequenceGap(node: String, expected: Int, actual: Int)
  DuplicateBatch(node: String, sequence: Int)
  ReceiptMismatch(node: String, field: String, expected: Int, actual: Int)
  DrainTimeout(node: String, timeout_ms: Int)
  LegacyUnverified(reason: String)
}

pub type NodeReceipt {
  NodeReceipt(
    node: String,
    final_batch_sequence: Int,
    event_count: Int,
    byte_count: Int,
  )
}

pub type CaptureOutcome {
  CaptureOutcome(
    end: ObservationEnd,
    issues: List(CaptureIssue),
    receipts: List(NodeReceipt),
  )
}

pub fn delivery_verified(outcome: CaptureOutcome) -> Bool {
  outcome.issues == [] && outcome.receipts != []
}

pub type TimeEstimate {
  ExactTime(value_ns: Int)
  EstimatedTime(value_ns: Int, lower_ns: Int, upper_ns: Int)
  TimeUnavailable(reason: String)
}

pub type TimeSummary {
  TimeSummary(estimate: TimeEstimate, valid_samples: Int, missing_samples: Int)
}

/// One minimum-RTT clock observation. Unix values are used only in this
/// calibration model and exporters; trace events remain node-relative.
pub type ClockSample {
  ClockSample(
    local_ns: Int,
    unix_midpoint_ns: Int,
    uncertainty_ns: Int,
    rtt_ns: Int,
  )
}

pub type NodeClock {
  NodeClock(
    node: String,
    origin_local_ns: Int,
    before: Option(ClockSample),
    after: Option(ClockSample),
  )
}

pub type ClockCalibration {
  ClockCalibration(capture_anchor_unix_ns: Int, nodes: List(NodeClock))
}

pub fn empty_calibration() -> ClockCalibration {
  ClockCalibration(0, [])
}

pub type Mfa {
  Mfa(module_: String, function_: String, arity: Int)
}

pub type ProcessRef {
  ProcessRef(node: String, pid: String)
}

pub type LogicalActor {
  LogicalActor(id: String, label: String)
}

pub type IdentityEvidence {
  RegisteredName(name: String)
  ProcessLabel(label: String)
  InitialCall(mfa: Mfa)
  Ancestor(name: String)
  SupervisorChildId(id: String)
  RestartProximity(milliseconds: Int)
}

pub type ProcessIdentity {
  ProcessIdentity(
    physical: ProcessRef,
    logical: Option(LogicalActor),
    evidence: List(IdentityEvidence),
  )
}

pub type ProcessMetadata {
  ProcessMetadata(
    registered_name: Option(String),
    process_label: Option(String),
    initial_call: Option(Mfa),
    ancestors: List(String),
    supervisor_child_id: Option(String),
  )
}

/// A deliberately finite representation of arbitrary BEAM terms.
pub type RawTerm {
  RawAtom(name: String)
  RawInt(value: Int)
  RawFloat(value: Float)
  RawString(value: String)
  RawBinary(value: String, bytes: Int)
  RawTuple(items: List(RawTerm))
  RawConstructor(name: String, fields: List(RawTerm))
  RawList(items: List(RawTerm))
  RawMap(entries: List(#(RawTerm, RawTerm)))
  RawHidden
}

/// The only term representation that may cross the relay boundary.
pub type TermView {
  Hidden
  Atom(name: String)
  Tag(name: String)
  Tuple(items: List(TermView))
  Constructor(name: String, fields: List(TermView))
  ListView(length: Int, items: List(TermView))
  MapView(size: Int, entries: List(#(TermView, TermView)))
  BinaryMetadata(
    bytes: Int,
    display: Option(String),
    fingerprint: Option(String),
  )
  Scalar(kind: String, display: Option(String), fingerprint: Option(String))
  Redacted(reason: String)
}

pub type RawPolicy {
  RawPolicy(redact_keys: List(String), max_depth: Int, max_binary_bytes: Int)
}

pub type Privacy {
  Metadata
  Raw(policy: RawPolicy)
}

pub type TraceBudget {
  TraceBudget(
    max_events: Int,
    max_bytes: Int,
    max_duration_ms: Int,
    drain_timeout_ms: Int,
    max_agent_mailbox: Int,
    max_roots: Int,
  )
}

pub fn default_budget() -> TraceBudget {
  TraceBudget(
    max_events: 100_000,
    max_bytes: 64_000_000,
    max_duration_ms: 30_000,
    drain_timeout_ms: 10_000,
    max_agent_mailbox: 10_000,
    max_roots: 1,
  )
}

pub type Preset {
  Generic
  GleamActor
  WispMist
  GenServer
  Phoenix
  ErlangSupervisor
}

pub type CaptureSpec {
  CaptureSpec(
    nodes: List(String),
    trigger: Mfa,
    where_aql: Option(String),
    privacy: Privacy,
    budget: TraceBudget,
    preset: Preset,
  )
}

pub fn default_capture_spec(trigger: Mfa) -> CaptureSpec {
  CaptureSpec(
    nodes: [],
    trigger: trigger,
    where_aql: None,
    privacy: Metadata,
    budget: default_budget(),
    preset: Generic,
  )
}

pub type TraceEventKind {
  Root(trigger: Mfa, arguments: List(TermView))
  Send(to: ProcessRef, message: TermView, serial: SequenceSerial)
  Received(from: ProcessRef, message: TermView, serial: SequenceSerial)
  Spawn(child: ProcessRef, initial_call: Mfa)
  Exit(reason: TermView)
  Register(name: String)
  Link(peer: ProcessRef)
  Metric(name: String, value: Float)
  SystemSignal(name: String, value: Int)
  Gap(dropped_events: Int, reason: String)
  Stop(reason: String)
}

pub type TraceEvent {
  TraceEvent(
    id: String,
    root_id: String,
    node: String,
    process: ProcessIdentity,
    local_instant: LocalInstant,
    kind: TraceEventKind,
    evidence: Evidence,
  )
}

pub type EdgeKind {
  SequentialMessage(serial: SequenceSerial)
  ProcessOrder
  Spawned
  LinkRelationship
  InferredRelation(reason: String)
  ExternalBoundary
  UnobservedState
}

pub type CausalEdge {
  CausalEdge(from: String, to: String, kind: EdgeKind, evidence: Evidence)
}

pub type Boundary {
  Boundary(event_id: String, kind: EdgeKind, reason: String)
}
