import gleam/option.{type Option, None}

/// Every observation and inference in BeamTrace carries its epistemic status.
pub type Evidence {
  Exact
  Inferred(reason: String, confidence: Float)
}

/// Construct inferred evidence while preserving the public 0..1 invariant.
pub fn inferred(reason: String, confidence: Float) -> Evidence {
  Inferred(reason, float_clamp(confidence, 0.0, 1.0))
}

fn float_clamp(value: Float, minimum: Float, maximum: Float) -> Float {
  case value <. minimum, value >. maximum {
    True, _ -> minimum
    _, True -> maximum
    _, _ -> value
  }
}

pub type Completeness {
  Complete
  Truncated(reason: String)
  Gapped(dropped_events: Int)
  PartialNode(missing_nodes: List(String))
  InferredCapture(reason: String)
}

pub fn is_complete(value: Completeness) -> Bool {
  value == Complete
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
    max_agent_mailbox: Int,
    max_roots: Int,
  )
}

pub fn default_budget() -> TraceBudget {
  TraceBudget(
    max_events: 100_000,
    max_bytes: 64_000_000,
    max_duration_ms: 30_000,
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
  Send(to: ProcessRef, message: TermView, serial: Int)
  Received(from: ProcessRef, message: TermView, serial: Int)
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
    local_timestamp_ns: Int,
    kind: TraceEventKind,
    evidence: Evidence,
  )
}

pub type EdgeKind {
  SequentialMessage(serial: Int)
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
