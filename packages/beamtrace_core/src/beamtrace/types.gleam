//// Portable evidence, capture, time, privacy, and causal-event contracts.
////
//// Constructors preserve node-relative time and explicit uncertainty; they do
//// not perform I/O or invent completeness. Construction and field access are
//// O(1), while callers validate untrusted values through `beamtrace` or
//// `beamtrace/codec`. All types have identical Erlang and JavaScript meaning.

import gleam/option.{type Option, None}

/// Every observation and inference in BeamTrace carries its epistemic status.
/// Inferences are reproducible claims, not probabilities: the method, reason,
/// evidence events, observations, and settings are all retained.
pub type InferenceInput {
  EvidenceEvent(id: String)
  ObservedValue(name: String, value: String)
  AlgorithmSetting(name: String, value: String)
}

/// A reproducible inference method, human-readable reason, and complete inputs.
pub type Inference {
  Inference(method: String, reason: String, inputs: List(InferenceInput))
}

/// Whether a value was directly observed or derived by a stated inference.
pub type Evidence {
  Exact
  Inferred(inference: Inference)
}

/// Construct attributed inferred evidence in O(1). Validation of untrusted
/// method, reason, and input lengths is performed by `beamtrace/codec`.
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

/// OTP sequence-trace continuity. Schema v2 retains previous/current values;
/// `LegacySerial` preserves the less precise v1 representation.
pub type SequenceSerial {
  SequenceSerial(previous: Int, current: Int)
  LegacySerial(current: Int)
}

/// The explicit condition that ended a bounded observation.
pub type ObservationEnd {
  QuietPeriod(quiet_ms: Int)
  TimeWindow(window_ms: Int)
  UserStopped
  BudgetReached(budget: String)
  AgentFailure(node: String, reason: String)
  LegacyUnknown
}

/// An integrity condition that limits conclusions drawn from a capture.
pub type CaptureIssue {
  DroppedEvents(node: String, count: Int)
  MissingNode(node: String)
  BatchSequenceGap(node: String, expected: Int, actual: Int)
  DuplicateBatch(node: String, sequence: Int)
  ReceiptMismatch(node: String, field: String, expected: Int, actual: Int)
  DrainTimeout(node: String, timeout_ms: Int)
  LegacyUnverified(reason: String)
}

/// A final per-node receipt used to verify delivered event and byte counts.
pub type NodeReceipt {
  NodeReceipt(
    node: String,
    final_batch_sequence: Int,
    event_count: Int,
    byte_count: Int,
  )
}

/// Observation end, integrity issues, and final receipts kept as separate facts.
pub type CaptureOutcome {
  CaptureOutcome(
    end: ObservationEnd,
    issues: List(CaptureIssue),
    receipts: List(NodeReceipt),
  )
}

/// Return true only when at least one final receipt exists and no issue was
/// recorded. This conservative O(issues) check cannot fail.
pub fn delivery_verified(outcome: CaptureOutcome) -> Bool {
  outcome.issues == [] && outcome.receipts != []
}

/// Exact time, an uncertainty interval, or an explicit unavailability reason.
pub type TimeEstimate {
  ExactTime(value_ns: Int)
  EstimatedTime(value_ns: Int, lower_ns: Int, upper_ns: Int)
  TimeUnavailable(reason: String)
}

/// An interval-aware aggregate with valid and missing sample counts.
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

/// Before/after minimum-RTT samples for one captured node.
pub type NodeClock {
  NodeClock(
    node: String,
    origin_local_ns: Int,
    before: Option(ClockSample),
    after: Option(ClockSample),
  )
}

/// Capture clock anchor and all node calibration evidence.
pub type ClockCalibration {
  ClockCalibration(capture_anchor_unix_ns: Int, nodes: List(NodeClock))
}

/// Construct the neutral calibration with no node clocks in O(1).
pub fn empty_calibration() -> ClockCalibration {
  ClockCalibration(0, [])
}

/// A module/function/arity target. Parse untrusted text with `beamtrace/mfa`.
pub type Mfa {
  Mfa(module: String, function: String, arity: Int)
}

/// A physical BEAM process reference scoped by node.
pub type ProcessRef {
  ProcessRef(node: String, pid: String)
}

/// A PID-independent actor identifier and display label.
pub type LogicalActor {
  LogicalActor(id: String, label: String)
}

/// One observed fact used to resolve a logical actor identity.
pub type IdentityEvidence {
  RegisteredName(name: String)
  ProcessLabel(label: String)
  InitialCall(mfa: Mfa)
  Ancestor(name: String)
  SupervisorChildId(id: String)
  RestartProximity(milliseconds: Int)
}

/// Physical identity plus optional evidence-derived logical identity.
pub type ProcessIdentity {
  ProcessIdentity(
    physical: ProcessRef,
    logical: Option(LogicalActor),
    evidence: List(IdentityEvidence),
  )
}

/// Bounded metadata accepted by the logical identity resolver.
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
  TagOnly(name: String)
  Tuple(items: List(TermView))
  Constructor(name: String, fields: List(TermView))
  BoundedList(length: Int, items: List(TermView))
  BoundedMap(size: Int, entries: List(#(TermView, TermView)))
  BinaryMetadata(
    bytes: Int,
    display: Option(String),
    fingerprint: Option(String),
  )
  Scalar(kind: String, display: Option(String), fingerprint: Option(String))
  Redacted(reason: String)
}

/// Required redaction keys and structural limits for explicitly authorized raw
/// capture material.
pub type RawPolicy {
  RawPolicy(redact_keys: List(String), max_depth: Int, max_binary_bytes: Int)
}

/// Metadata-only capture or raw capture guarded by an explicit finite policy.
pub type Privacy {
  Metadata
  Raw(policy: RawPolicy)
}

/// Hard limits for event count, bytes, duration, drain, mailbox, and roots.
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

/// Return the conservative bounded capture limits in O(1).
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

/// A finite framework hint used only to improve recognized causal metadata.
pub type Preset {
  Generic
  GleamActor
  WispMist
  GenServer
  Phoenix
  ErlangSupervisor
}

/// Nodes, trigger, optional AQL, privacy, budgets, and framework hint for one
/// capture. Runtime code validates it before touching a VM.
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

/// Build a metadata-first single-root specification in O(1). The caller adds
/// nodes and runtime validation before execution.
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

/// A finite captured event payload; gaps and stop reasons remain first-class.
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

/// One node-relative event with stable identity and explicit evidence.
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

/// A causal relation kind, including explicit inferred and boundary relations.
pub type EdgeKind {
  SequentialMessage(serial: SequenceSerial)
  ProcessOrder
  Spawned
  LinkRelationship
  InferredRelation(reason: String)
  ExternalBoundary
  UnobservedState
}

/// A directed relation between event identifiers with stated evidence.
pub type CausalEdge {
  CausalEdge(from: String, to: String, kind: EdgeKind, evidence: Evidence)
}

/// A point where a requested causal relation leaves the observation.
pub type Boundary {
  Boundary(event_id: String, kind: EdgeKind, reason: String)
}
