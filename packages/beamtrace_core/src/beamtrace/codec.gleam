//// Canonical archive-v2 JSON encoding, decoding, and typed validation.
////
//// Decoders reject malformed, non-canonical, unknown-version, and invalid
//// field data with `CodecError`; no permissive coercion is performed. Work is
//// linear in the encoded value plus bounded nested collections. On either
//// target, decoding an encoded valid event round-trips it.

import beamtrace/types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string

/// The canonical archive and event schema emitted by this release.
pub const schema_version = 2

/// A stable decoding or typed validation failure. `InvalidJson` deliberately
/// avoids exposing runtime-specific parser internals.
pub type CodecError {
  InvalidJson(message: String)
  UnknownSchemaVersion(version: Int)
  NonCanonicalJson
  InvalidField(field: String, reason: String)
}

/// Archive metadata, declared nodes, observation outcome, and privacy policy.
pub type Manifest {
  Manifest(
    schema_version: Int,
    tool_version: String,
    capture_id: String,
    nodes: List(String),
    outcome: types.CaptureOutcome,
    privacy: types.Privacy,
  )
}

/// A bounded serialized slice of event identifiers, causal edges, and explicit
/// observation boundaries.
pub type GraphSegment {
  GraphSegment(
    event_ids: List(String),
    edges: List(types.CausalEdge),
    boundaries: List(types.Boundary),
  )
}

type VersionedEvent {
  EventV1(types.TraceEvent)
  EventV2(types.TraceEvent)
  UnsupportedEvent(Int)
}

type VersionedManifest {
  ManifestV1(Manifest)
  ManifestV2(Manifest)
  UnsupportedManifest(Int)
}

type VersionedGraphSegment {
  GraphSegmentV2(GraphSegment)
  UnsupportedGraphSegment(Int)
}

type VersionedClocks {
  ClocksV2(types.ClockCalibration)
  UnsupportedClocks(Int)
}

/// Encode one validated event to canonical schema-v2 JSON in O(event size).
pub fn encode_event(event: types.TraceEvent) -> String {
  event_json(event) |> json.to_string
}

/// Decode and validate one canonical event in O(source length). Schema v1 is
/// adapted; malformed, unsupported, or non-canonical v2 input is rejected.
pub fn decode_event(source: String) -> Result(types.TraceEvent, CodecError) {
  case decode_versioned_event(source) {
    Error(error) -> Error(error)
    Ok(#(event, 2)) ->
      case encode_event(event) == source {
        True -> Ok(event)
        False -> Error(NonCanonicalJson)
      }
    Ok(#(event, 1)) -> Ok(event)
    Ok(#(_, version)) -> Error(UnknownSchemaVersion(version))
  }
}

/// Structural decoder for protocol boundaries that have already enforced an
/// exact recursive object shape. Archive segments must use `decode_event`,
/// which additionally requires BeamTrace's canonical byte representation.
pub fn decode_event_structural(
  source: String,
) -> Result(types.TraceEvent, CodecError) {
  case decode_versioned_event(source) {
    Ok(#(event, _)) -> Ok(event)
    Error(error) -> Error(error)
  }
}

fn decode_versioned_event(
  source: String,
) -> Result(#(types.TraceEvent, Int), CodecError) {
  case json.parse(source, versioned_event_decoder()) {
    Error(_) -> Error(InvalidJson("JSON does not match the expected schema"))
    Ok(EventV2(event)) -> validate_event(event) |> result_replace(#(event, 2))
    Ok(EventV1(event)) ->
      validate_legacy_event(event) |> result_replace(#(event, 1))
    Ok(UnsupportedEvent(version)) -> Error(UnknownSchemaVersion(version))
  }
}

/// Encode a manifest to canonical schema-v2 JSON in O(manifest size).
pub fn encode_manifest(manifest: Manifest) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("tool_version", json.string(manifest.tool_version)),
    #("capture_id", json.string(manifest.capture_id)),
    #("nodes", json.array(manifest.nodes, json.string)),
    #("outcome", outcome_json(manifest.outcome)),
    #("privacy", privacy_json(manifest.privacy)),
  ])
  |> json.to_string
}

/// Decode and validate a manifest in O(source length), rejecting unknown
/// versions, invalid fields, and non-canonical schema-v2 bytes.
pub fn decode_manifest(source: String) -> Result(Manifest, CodecError) {
  case json.parse(source, versioned_manifest_decoder()) {
    Error(_) -> Error(InvalidJson("JSON does not match the expected schema"))
    Ok(ManifestV2(manifest)) ->
      case validate_manifest(manifest) {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case encode_manifest(manifest) == source {
            True -> Ok(manifest)
            False -> Error(NonCanonicalJson)
          }
      }
    Ok(ManifestV1(manifest)) ->
      validate_manifest(manifest) |> result_replace(manifest)
    Ok(UnsupportedManifest(version)) -> Error(UnknownSchemaVersion(version))
  }
}

/// Encode a trace event as a JSON object for structured protocol consumers.
pub fn event_json(event: types.TraceEvent) -> json.Json {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("id", json.string(event.id)),
    #("root_id", json.string(event.root_id)),
    #("node", json.string(event.node)),
    #("process", process_identity_json(event.process)),
    #("local_instant", local_instant_json(event.local_instant)),
    #("event", event_kind_json(event.kind)),
    #("evidence", evidence_json(event.evidence)),
  ])
}

/// Lossy API-v1 projection used only by the one-release compatibility
/// adapter. Callers must first prove that the calibrated instant is a point
/// value and that evidence is exact; this function never invents confidence.
pub fn event_v1_adapter_json(
  event: types.TraceEvent,
  timestamp_ns: Int,
) -> json.Json {
  json.object([
    #("schema_version", json.int(1)),
    #("id", json.string(event.id)),
    #("root_id", json.string(event.root_id)),
    #("node", json.string(event.node)),
    #("process", process_identity_json(event.process)),
    #("local_timestamp_ns", json.int(timestamp_ns)),
    #("event", event_kind_json_v1(event.kind)),
    #("evidence", json.object([#("kind", json.string("exact"))])),
  ])
}

fn mfa_json(mfa: types.Mfa) -> json.Json {
  json.object([
    #("module", json.string(mfa.module_)),
    #("function", json.string(mfa.function_)),
    #("arity", json.int(mfa.arity)),
  ])
}

fn process_ref_json(process: types.ProcessRef) -> json.Json {
  json.object([
    #("node", json.string(process.node)),
    #("pid", json.string(process.pid)),
  ])
}

fn logical_actor_json(actor: types.LogicalActor) -> json.Json {
  json.object([
    #("id", json.string(actor.id)),
    #("label", json.string(actor.label)),
  ])
}

fn process_identity_json(process: types.ProcessIdentity) -> json.Json {
  json.object([
    #("physical", process_ref_json(process.physical)),
    #("logical", json.nullable(process.logical, logical_actor_json)),
    #("identity_evidence", json.array(process.evidence, identity_evidence_json)),
  ])
}

fn identity_evidence_json(evidence: types.IdentityEvidence) -> json.Json {
  case evidence {
    types.RegisteredName(value) -> tagged_string("registered_name", value)
    types.ProcessLabel(value) -> tagged_string("process_label", value)
    types.InitialCall(value) ->
      json.object([
        #("kind", json.string("initial_call")),
        #("mfa", mfa_json(value)),
      ])
    types.Ancestor(value) -> tagged_string("ancestor", value)
    types.SupervisorChildId(value) ->
      tagged_string("supervisor_child_id", value)
    types.RestartProximity(value) ->
      json.object([
        #("kind", json.string("restart_proximity")),
        #("milliseconds", json.int(value)),
      ])
  }
}

fn tagged_string(kind: String, value: String) -> json.Json {
  json.object([
    #("kind", json.string(kind)),
    #("value", json.string(value)),
  ])
}

/// Encode exact or fully attributed inferred evidence in O(input count).
pub fn evidence_json(evidence: types.Evidence) -> json.Json {
  case evidence {
    types.Exact -> json.object([#("kind", json.string("exact"))])
    types.Inferred(inference) ->
      json.object([
        #("kind", json.string("inferred")),
        #("inference", inference_json(inference)),
      ])
  }
}

fn inference_json(inference: types.Inference) -> json.Json {
  json.object([
    #("method", json.string(inference.method)),
    #("reason", json.string(inference.reason)),
    #("inputs", json.array(inference.inputs, inference_input_json)),
  ])
}

fn inference_input_json(input: types.InferenceInput) -> json.Json {
  case input {
    types.EvidenceEvent(id) ->
      json.object([
        #("kind", json.string("event")),
        #("id", json.string(id)),
      ])
    types.ObservedValue(name, value) ->
      json.object([
        #("kind", json.string("observation")),
        #("name", json.string(name)),
        #("value", json.string(value)),
      ])
    types.AlgorithmSetting(name, value) ->
      json.object([
        #("kind", json.string("setting")),
        #("name", json.string(name)),
        #("value", json.string(value)),
      ])
  }
}

fn local_instant_json(instant: types.LocalInstant) -> json.Json {
  json.object([
    #("offset_ns", json.int(instant.offset_ns)),
    #("order", json.int(instant.order)),
  ])
}

fn serial_json(serial: types.SequenceSerial) -> json.Json {
  case serial {
    types.SequenceSerial(previous, current) ->
      json.object([
        #("kind", json.string("sequence")),
        #("previous", json.int(previous)),
        #("current", json.int(current)),
      ])
    types.LegacySerial(current) ->
      json.object([
        #("kind", json.string("legacy")),
        #("current", json.int(current)),
      ])
  }
}

fn event_kind_json(kind: types.TraceEventKind) -> json.Json {
  case kind {
    types.Root(trigger, arguments) ->
      json.object([
        #("kind", json.string("root")),
        #("trigger", mfa_json(trigger)),
        #("arguments", json.array(arguments, term_json)),
      ])
    types.Send(to, message, serial) ->
      json.object([
        #("kind", json.string("send")),
        #("to", process_ref_json(to)),
        #("message", term_json(message)),
        #("serial", serial_json(serial)),
      ])
    types.Received(from, message, serial) ->
      json.object([
        #("kind", json.string("receive")),
        #("from", process_ref_json(from)),
        #("message", term_json(message)),
        #("serial", serial_json(serial)),
      ])
    types.Spawn(child, initial_call) ->
      json.object([
        #("kind", json.string("spawn")),
        #("child", process_ref_json(child)),
        #("initial_call", mfa_json(initial_call)),
      ])
    types.Exit(reason) ->
      json.object([
        #("kind", json.string("exit")),
        #("reason", term_json(reason)),
      ])
    types.Register(name) -> tagged_string("register", name)
    types.Link(peer) ->
      json.object([
        #("kind", json.string("link")),
        #("peer", process_ref_json(peer)),
      ])
    types.Metric(name, value) ->
      json.object([
        #("kind", json.string("metric")),
        #("name", json.string(name)),
        #("value", json.float(value)),
      ])
    types.SystemSignal(name, value) ->
      json.object([
        #("kind", json.string("system_signal")),
        #("name", json.string(name)),
        #("value", json.int(value)),
      ])
    types.Gap(dropped_events, reason) ->
      json.object([
        #("kind", json.string("gap")),
        #("dropped_events", json.int(dropped_events)),
        #("reason", json.string(reason)),
      ])
    types.Stop(reason) -> tagged_string("stop", reason)
  }
}

fn event_kind_json_v1(kind: types.TraceEventKind) -> json.Json {
  case kind {
    types.Send(to, message, serial) ->
      json.object([
        #("kind", json.string("send")),
        #("to", process_ref_json(to)),
        #("message", term_json(message)),
        #("serial", json.int(serial_current(serial))),
      ])
    types.Received(from, message, serial) ->
      json.object([
        #("kind", json.string("receive")),
        #("from", process_ref_json(from)),
        #("message", term_json(message)),
        #("serial", json.int(serial_current(serial))),
      ])
    other -> event_kind_json(other)
  }
}

fn serial_current(serial: types.SequenceSerial) -> Int {
  case serial {
    types.SequenceSerial(_, current) | types.LegacySerial(current) -> current
  }
}

fn term_json(term: types.TermView) -> json.Json {
  case term {
    types.Hidden -> json.object([#("kind", json.string("hidden"))])
    types.Atom(name) -> tagged_string("atom", name)
    types.Tag(name) -> tagged_string("tag", name)
    types.Tuple(items) ->
      json.object([
        #("kind", json.string("tuple")),
        #("items", json.array(items, term_json)),
      ])
    types.Constructor(name, fields) ->
      json.object([
        #("kind", json.string("constructor")),
        #("name", json.string(name)),
        #("fields", json.array(fields, term_json)),
      ])
    types.ListView(length, items) ->
      json.object([
        #("kind", json.string("list")),
        #("length", json.int(length)),
        #("items", json.array(items, term_json)),
      ])
    types.MapView(size, entries) ->
      json.object([
        #("kind", json.string("map")),
        #("size", json.int(size)),
        #(
          "entries",
          json.array(entries, fn(entry) {
            let #(key, value) = entry
            json.object([#("key", term_json(key)), #("value", term_json(value))])
          }),
        ),
      ])
    types.BinaryMetadata(bytes, display, fingerprint) ->
      json.object([
        #("kind", json.string("binary")),
        #("bytes", json.int(bytes)),
        #("display", json.nullable(display, json.string)),
        #("fingerprint", json.nullable(fingerprint, json.string)),
      ])
    types.Scalar(scalar_kind, display, fingerprint) ->
      json.object([
        #("kind", json.string("scalar")),
        #("scalar_kind", json.string(scalar_kind)),
        #("display", json.nullable(display, json.string)),
        #("fingerprint", json.nullable(fingerprint, json.string)),
      ])
    types.Redacted(reason) -> tagged_string("redacted", reason)
  }
}

/// Encode the observation end, integrity issues, and delivery receipts without
/// collapsing them to a completeness boolean. Work is O(issues + receipts).
pub fn outcome_json(outcome: types.CaptureOutcome) -> json.Json {
  json.object([
    #("end", observation_end_json(outcome.end)),
    #("issues", json.array(outcome.issues, capture_issue_json)),
    #("receipts", json.array(outcome.receipts, receipt_json)),
  ])
}

/// Encode a duration or calibrated instant without collapsing an uncertainty
/// interval to a misleading point value.
pub fn time_estimate_json(estimate: types.TimeEstimate) -> json.Json {
  case estimate {
    types.ExactTime(value) ->
      json.object([
        #("kind", json.string("exact")),
        #("value_ns", json.string(int.to_string(value))),
      ])
    types.EstimatedTime(value, lower, upper) ->
      json.object([
        #("kind", json.string("estimated")),
        #("value_ns", json.string(int.to_string(value))),
        #("lower_ns", json.string(int.to_string(lower))),
        #("upper_ns", json.string(int.to_string(upper))),
      ])
    types.TimeUnavailable(reason) ->
      json.object([
        #("kind", json.string("unavailable")),
        #("reason", json.string(reason)),
      ])
  }
}

/// Encode a multi-run time summary and its valid/missing sample counts in O(1).
pub fn time_summary_json(summary: types.TimeSummary) -> json.Json {
  json.object([
    #("estimate", time_estimate_json(summary.estimate)),
    #("valid_samples", json.int(summary.valid_samples)),
    #("missing_samples", json.int(summary.missing_samples)),
  ])
}

fn observation_end_json(end: types.ObservationEnd) -> json.Json {
  case end {
    types.QuietPeriod(quiet_ms) ->
      json.object([
        #("kind", json.string("quiet_period")),
        #("quiet_ms", json.int(quiet_ms)),
      ])
    types.TimeWindow(window_ms) ->
      json.object([
        #("kind", json.string("time_window")),
        #("window_ms", json.int(window_ms)),
      ])
    types.UserStopped -> json.object([#("kind", json.string("user_stopped"))])
    types.BudgetReached(budget) ->
      json.object([
        #("kind", json.string("budget_reached")),
        #("budget", json.string(budget)),
      ])
    types.AgentFailure(node, reason) ->
      json.object([
        #("kind", json.string("agent_failure")),
        #("node", json.string(node)),
        #("reason", json.string(reason)),
      ])
    types.LegacyUnknown ->
      json.object([#("kind", json.string("legacy_unknown"))])
  }
}

fn capture_issue_json(issue: types.CaptureIssue) -> json.Json {
  case issue {
    types.DroppedEvents(node, count) ->
      json.object([
        #("kind", json.string("dropped_events")),
        #("node", json.string(node)),
        #("count", json.int(count)),
      ])
    types.MissingNode(node) ->
      json.object([
        #("kind", json.string("missing_node")),
        #("node", json.string(node)),
      ])
    types.BatchSequenceGap(node, expected, actual) ->
      sequence_issue_json("batch_sequence_gap", node, expected, actual)
    types.DuplicateBatch(node, sequence) ->
      json.object([
        #("kind", json.string("duplicate_batch")),
        #("node", json.string(node)),
        #("sequence", json.int(sequence)),
      ])
    types.ReceiptMismatch(node, field, expected, actual) ->
      json.object([
        #("kind", json.string("receipt_mismatch")),
        #("node", json.string(node)),
        #("field", json.string(field)),
        #("expected", json.int(expected)),
        #("actual", json.int(actual)),
      ])
    types.DrainTimeout(node, timeout_ms) ->
      json.object([
        #("kind", json.string("drain_timeout")),
        #("node", json.string(node)),
        #("timeout_ms", json.int(timeout_ms)),
      ])
    types.LegacyUnverified(reason) ->
      json.object([
        #("kind", json.string("legacy_unverified")),
        #("reason", json.string(reason)),
      ])
  }
}

fn sequence_issue_json(
  kind: String,
  node: String,
  expected: Int,
  actual: Int,
) -> json.Json {
  json.object([
    #("kind", json.string(kind)),
    #("node", json.string(node)),
    #("expected", json.int(expected)),
    #("actual", json.int(actual)),
  ])
}

fn receipt_json(receipt: types.NodeReceipt) -> json.Json {
  json.object([
    #("node", json.string(receipt.node)),
    #("final_batch_sequence", json.int(receipt.final_batch_sequence)),
    #("event_count", json.int(receipt.event_count)),
    #("byte_count", json.int(receipt.byte_count)),
  ])
}

/// Encode a bounded graph segment to canonical schema-v2 JSON in O(v + e).
pub fn encode_graph_segment(segment: GraphSegment) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("event_ids", json.array(segment.event_ids, json.string)),
    #("edges", json.array(segment.edges, edge_json)),
    #("boundaries", json.array(segment.boundaries, boundary_json)),
  ])
  |> json.to_string
}

fn edge_json(edge: types.CausalEdge) -> json.Json {
  json.object([
    #("from", json.string(edge.from)),
    #("to", json.string(edge.to)),
    #("kind", edge_kind_json(edge.kind)),
    #("evidence", evidence_json(edge.evidence)),
  ])
}

fn boundary_json(boundary: types.Boundary) -> json.Json {
  json.object([
    #("event_id", json.string(boundary.event_id)),
    #("kind", edge_kind_json(boundary.kind)),
    #("reason", json.string(boundary.reason)),
  ])
}

fn edge_kind_json(kind: types.EdgeKind) -> json.Json {
  case kind {
    types.SequentialMessage(serial) ->
      json.object([
        #("kind", json.string("sequential_message")),
        #("serial", serial_json(serial)),
      ])
    types.ProcessOrder -> tagged_kind("process_order")
    types.Spawned -> tagged_kind("spawned")
    types.LinkRelationship -> tagged_kind("link_relationship")
    types.InferredRelation(reason) ->
      json.object([
        #("kind", json.string("inferred_relation")),
        #("reason", json.string(reason)),
      ])
    types.ExternalBoundary -> tagged_kind("external_boundary")
    types.UnobservedState -> tagged_kind("unobserved_state")
  }
}

fn tagged_kind(kind: String) -> json.Json {
  json.object([#("kind", json.string(kind))])
}

/// Encode clock calibration to canonical schema-v2 JSON in O(nodes).
pub fn encode_clocks(calibration: types.ClockCalibration) -> String {
  clocks_json(calibration) |> json.to_string
}

/// Build the structured clock-calibration JSON value in O(nodes).
pub fn clocks_json(calibration: types.ClockCalibration) -> json.Json {
  json.object([
    #("schema_version", json.int(schema_version)),
    #(
      "capture_anchor_unix_ns",
      json.string(int.to_string(calibration.capture_anchor_unix_ns)),
    ),
    #("nodes", json.array(calibration.nodes, node_clock_json)),
  ])
}

fn node_clock_json(clock: types.NodeClock) -> json.Json {
  json.object([
    #("node", json.string(clock.node)),
    #("origin_local_ns", json.string(int.to_string(clock.origin_local_ns))),
    #("before", json.nullable(clock.before, clock_sample_json)),
    #("after", json.nullable(clock.after, clock_sample_json)),
  ])
}

fn clock_sample_json(sample: types.ClockSample) -> json.Json {
  json.object([
    #("local_ns", json.string(int.to_string(sample.local_ns))),
    #("unix_midpoint_ns", json.string(int.to_string(sample.unix_midpoint_ns))),
    #("uncertainty_ns", json.int(sample.uncertainty_ns)),
    #("rtt_ns", json.int(sample.rtt_ns)),
  ])
}

fn privacy_json(privacy: types.Privacy) -> json.Json {
  case privacy {
    types.Metadata -> json.object([#("kind", json.string("metadata"))])
    types.Raw(policy) ->
      json.object([
        #("kind", json.string("raw")),
        #("redact_keys", json.array(policy.redact_keys, json.string)),
        #("max_depth", json.int(policy.max_depth)),
        #("max_binary_bytes", json.int(policy.max_binary_bytes)),
      ])
  }
}

fn versioned_event_decoder() -> decode.Decoder(VersionedEvent) {
  use version <- decode.field("schema_version", decode.int)
  case version {
    1 -> decode.map(trace_event_decoder_v1(), EventV1)
    2 -> decode.map(trace_event_decoder_v2(), EventV2)
    version -> decode.success(UnsupportedEvent(version))
  }
}

fn versioned_manifest_decoder() -> decode.Decoder(VersionedManifest) {
  use version <- decode.field("schema_version", decode.int)
  case version {
    1 -> decode.map(manifest_decoder_v1(), ManifestV1)
    2 -> decode.map(manifest_decoder_v2(), ManifestV2)
    version -> decode.success(UnsupportedManifest(version))
  }
}

fn versioned_graph_segment_decoder() -> decode.Decoder(VersionedGraphSegment) {
  use version <- decode.field("schema_version", decode.int)
  case version {
    2 -> decode.map(graph_segment_decoder(), GraphSegmentV2)
    version -> decode.success(UnsupportedGraphSegment(version))
  }
}

fn versioned_clocks_decoder() -> decode.Decoder(VersionedClocks) {
  use version <- decode.field("schema_version", decode.int)
  case version {
    2 -> decode.map(clocks_decoder(), ClocksV2)
    version -> decode.success(UnsupportedClocks(version))
  }
}

fn manifest_decoder_v2() -> decode.Decoder(Manifest) {
  use schema_version <- decode.field("schema_version", decode.int)
  use tool_version <- decode.field("tool_version", decode.string)
  use capture_id <- decode.field("capture_id", decode.string)
  use nodes <- decode.field("nodes", decode.list(decode.string))
  use outcome <- decode.field("outcome", outcome_decoder())
  use privacy <- decode.field("privacy", privacy_decoder())
  decode.success(Manifest(
    schema_version,
    tool_version,
    capture_id,
    nodes,
    outcome,
    privacy,
  ))
}

fn manifest_decoder_v1() -> decode.Decoder(Manifest) {
  use version <- decode.field("schema_version", decode.int)
  use tool_version <- decode.field("tool_version", decode.string)
  use capture_id <- decode.field("capture_id", decode.string)
  use nodes <- decode.field("nodes", decode.list(decode.string))
  use outcome <- decode.field("completeness", legacy_outcome_decoder())
  use privacy <- decode.field("privacy", privacy_decoder())
  use _checksums <- decode.field("checksums", decode.list(checksum_decoder()))
  decode.success(Manifest(
    version,
    tool_version,
    capture_id,
    nodes,
    outcome,
    privacy,
  ))
}

fn checksum_decoder() -> decode.Decoder(#(String, String)) {
  use path <- decode.field("path", decode.string)
  use sha256 <- decode.field("sha256", decode.string)
  decode.success(#(path, sha256))
}

fn trace_event_decoder_v2() -> decode.Decoder(types.TraceEvent) {
  use _version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use root_id <- decode.field("root_id", decode.string)
  use node <- decode.field("node", decode.string)
  use process <- decode.field("process", process_identity_decoder())
  use local_instant <- decode.field("local_instant", local_instant_decoder())
  use kind <- decode.field("event", event_kind_decoder_v2())
  use evidence <- decode.field("evidence", evidence_decoder_v2())
  decode.success(types.TraceEvent(
    id,
    root_id,
    node,
    process,
    local_instant,
    kind,
    evidence,
  ))
}

fn trace_event_decoder_v1() -> decode.Decoder(types.TraceEvent) {
  use _version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use root_id <- decode.field("root_id", decode.string)
  use node <- decode.field("node", decode.string)
  use process <- decode.field("process", process_identity_decoder())
  use local_timestamp_ns <- decode.field("local_timestamp_ns", decode.int)
  use kind <- decode.field("event", event_kind_decoder_v1())
  use evidence <- decode.field("evidence", evidence_decoder_v1())
  decode.success(types.TraceEvent(
    id,
    root_id,
    node,
    process,
    types.LocalInstant(local_timestamp_ns, 0),
    kind,
    evidence,
  ))
}

fn local_instant_decoder() -> decode.Decoder(types.LocalInstant) {
  use offset <- decode.field("offset_ns", decode.int)
  use order <- decode.field("order", decode.int)
  decode.success(types.LocalInstant(offset, order))
}

fn mfa_decoder() -> decode.Decoder(types.Mfa) {
  use module_ <- decode.field("module", decode.string)
  use function_ <- decode.field("function", decode.string)
  use arity <- decode.field("arity", decode.int)
  decode.success(types.Mfa(module_, function_, arity))
}

fn process_ref_decoder() -> decode.Decoder(types.ProcessRef) {
  use node <- decode.field("node", decode.string)
  use pid <- decode.field("pid", decode.string)
  decode.success(types.ProcessRef(node, pid))
}

fn logical_actor_decoder() -> decode.Decoder(types.LogicalActor) {
  use id <- decode.field("id", decode.string)
  use label <- decode.field("label", decode.string)
  decode.success(types.LogicalActor(id, label))
}

fn process_identity_decoder() -> decode.Decoder(types.ProcessIdentity) {
  use physical <- decode.field("physical", process_ref_decoder())
  use logical <- decode.field(
    "logical",
    decode.optional(logical_actor_decoder()),
  )
  use evidence <- decode.field(
    "identity_evidence",
    decode.list(identity_evidence_decoder()),
  )
  decode.success(types.ProcessIdentity(physical, logical, evidence))
}

fn identity_evidence_decoder() -> decode.Decoder(types.IdentityEvidence) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "registered_name" -> string_field(types.RegisteredName)
    "process_label" -> string_field(types.ProcessLabel)
    "initial_call" -> {
      use mfa <- decode.field("mfa", mfa_decoder())
      decode.success(types.InitialCall(mfa))
    }
    "ancestor" -> string_field(types.Ancestor)
    "supervisor_child_id" -> string_field(types.SupervisorChildId)
    "restart_proximity" -> {
      use value <- decode.field("milliseconds", decode.int)
      decode.success(types.RestartProximity(value))
    }
    _ -> decode.failure(types.Ancestor(""), expected: "identity evidence")
  }
}

fn string_field(constructor: fn(String) -> a) -> decode.Decoder(a) {
  use value <- decode.field("value", decode.string)
  decode.success(constructor(value))
}

fn evidence_decoder_v2() -> decode.Decoder(types.Evidence) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "exact" -> decode.success(types.Exact)
    "inferred" -> {
      use inference <- decode.field("inference", inference_decoder())
      decode.success(types.Inferred(inference))
    }
    _ -> decode.failure(types.Exact, expected: "evidence")
  }
}

fn evidence_decoder_v1() -> decode.Decoder(types.Evidence) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "exact" -> decode.success(types.Exact)
    "inferred" -> {
      use reason <- decode.field("reason", decode.string)
      use _confidence <- decode.field("confidence", decode.float)
      decode.success(
        types.inferred("legacy_v1_inference", reason, [
          types.ObservedValue(
            "migration_warning",
            "v1 confidence was discarded because it was not calibrated",
          ),
        ]),
      )
    }
    _ -> decode.failure(types.Exact, expected: "evidence")
  }
}

fn inference_decoder() -> decode.Decoder(types.Inference) {
  use method <- decode.field("method", decode.string)
  use reason <- decode.field("reason", decode.string)
  use inputs <- decode.field("inputs", decode.list(inference_input_decoder()))
  decode.success(types.Inference(method, reason, inputs))
}

fn inference_input_decoder() -> decode.Decoder(types.InferenceInput) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "event" -> {
      use id <- decode.field("id", decode.string)
      decode.success(types.EvidenceEvent(id))
    }
    "observation" -> {
      use name <- decode.field("name", decode.string)
      use value <- decode.field("value", decode.string)
      decode.success(types.ObservedValue(name, value))
    }
    "setting" -> {
      use name <- decode.field("name", decode.string)
      use value <- decode.field("value", decode.string)
      decode.success(types.AlgorithmSetting(name, value))
    }
    _ ->
      decode.failure(types.ObservedValue("", ""), expected: "inference input")
  }
}

fn serial_decoder() -> decode.Decoder(types.SequenceSerial) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "sequence" -> {
      use previous <- decode.field("previous", decode.int)
      use current <- decode.field("current", decode.int)
      decode.success(types.SequenceSerial(previous, current))
    }
    "legacy" -> {
      use current <- decode.field("current", decode.int)
      decode.success(types.LegacySerial(current))
    }
    _ -> decode.failure(types.LegacySerial(0), expected: "sequence serial")
  }
}

fn event_kind_decoder_v2() -> decode.Decoder(types.TraceEventKind) {
  event_kind_decoder(serial_decoder())
}

fn event_kind_decoder_v1() -> decode.Decoder(types.TraceEventKind) {
  event_kind_decoder(decode.map(decode.int, types.LegacySerial))
}

fn event_kind_decoder(
  serial_decoder_: decode.Decoder(types.SequenceSerial),
) -> decode.Decoder(types.TraceEventKind) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "root" -> {
      use trigger <- decode.field("trigger", mfa_decoder())
      use arguments <- decode.field("arguments", decode.list(term_decoder()))
      decode.success(types.Root(trigger, arguments))
    }
    "send" -> {
      use to <- decode.field("to", process_ref_decoder())
      use message <- decode.field("message", term_decoder())
      use serial <- decode.field("serial", serial_decoder_)
      decode.success(types.Send(to, message, serial))
    }
    "receive" -> {
      use from <- decode.field("from", process_ref_decoder())
      use message <- decode.field("message", term_decoder())
      use serial <- decode.field("serial", serial_decoder_)
      decode.success(types.Received(from, message, serial))
    }
    "spawn" -> {
      use child <- decode.field("child", process_ref_decoder())
      use initial_call <- decode.field("initial_call", mfa_decoder())
      decode.success(types.Spawn(child, initial_call))
    }
    "exit" -> {
      use reason <- decode.field("reason", term_decoder())
      decode.success(types.Exit(reason))
    }
    "register" -> {
      use name <- decode.field("value", decode.string)
      decode.success(types.Register(name))
    }
    "link" -> {
      use peer <- decode.field("peer", process_ref_decoder())
      decode.success(types.Link(peer))
    }
    "metric" -> {
      use name <- decode.field("name", decode.string)
      use value <- decode.field("value", decode.float)
      decode.success(types.Metric(name, value))
    }
    "system_signal" -> {
      use name <- decode.field("name", decode.string)
      use value <- decode.field("value", decode.int)
      decode.success(types.SystemSignal(name, value))
    }
    "gap" -> {
      use dropped <- decode.field("dropped_events", decode.int)
      use reason <- decode.field("reason", decode.string)
      decode.success(types.Gap(dropped, reason))
    }
    "stop" -> {
      use reason <- decode.field("value", decode.string)
      decode.success(types.Stop(reason))
    }
    _ -> decode.failure(types.Stop("invalid"), expected: "trace event kind")
  }
}

fn term_decoder() -> decode.Decoder(types.TermView) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "hidden" -> decode.success(types.Hidden)
    "atom" -> {
      use value <- decode.field("value", decode.string)
      decode.success(types.Atom(value))
    }
    "tag" -> {
      use value <- decode.field("value", decode.string)
      decode.success(types.Tag(value))
    }
    "tuple" -> {
      use items <- decode.field("items", decode.list(term_decoder()))
      decode.success(types.Tuple(items))
    }
    "constructor" -> {
      use name <- decode.field("name", decode.string)
      use fields <- decode.field("fields", decode.list(term_decoder()))
      decode.success(types.Constructor(name, fields))
    }
    "list" -> {
      use length <- decode.field("length", decode.int)
      use items <- decode.field("items", decode.list(term_decoder()))
      decode.success(types.ListView(length, items))
    }
    "map" -> {
      use size <- decode.field("size", decode.int)
      use entries <- decode.field("entries", decode.list(entry_decoder()))
      decode.success(types.MapView(size, entries))
    }
    "binary" -> {
      use bytes <- decode.field("bytes", decode.int)
      use display <- decode.field("display", decode.optional(decode.string))
      use fingerprint <- decode.field(
        "fingerprint",
        decode.optional(decode.string),
      )
      decode.success(types.BinaryMetadata(bytes, display, fingerprint))
    }
    "scalar" -> {
      use scalar_kind <- decode.field("scalar_kind", decode.string)
      use display <- decode.field("display", decode.optional(decode.string))
      use fingerprint <- decode.field(
        "fingerprint",
        decode.optional(decode.string),
      )
      decode.success(types.Scalar(scalar_kind, display, fingerprint))
    }
    "redacted" -> {
      use reason <- decode.field("value", decode.string)
      decode.success(types.Redacted(reason))
    }
    _ -> decode.failure(types.Hidden, expected: "term view")
  }
}

fn entry_decoder() -> decode.Decoder(#(types.TermView, types.TermView)) {
  use key <- decode.field("key", term_decoder())
  use value <- decode.field("value", term_decoder())
  decode.success(#(key, value))
}

fn outcome_decoder() -> decode.Decoder(types.CaptureOutcome) {
  use end <- decode.field("end", observation_end_decoder())
  use issues <- decode.field("issues", decode.list(capture_issue_decoder()))
  use receipts <- decode.field("receipts", decode.list(receipt_decoder()))
  decode.success(types.CaptureOutcome(end, issues, receipts))
}

fn observation_end_decoder() -> decode.Decoder(types.ObservationEnd) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "quiet_period" -> {
      use quiet_ms <- decode.field("quiet_ms", decode.int)
      decode.success(types.QuietPeriod(quiet_ms))
    }
    "time_window" -> {
      use window_ms <- decode.field("window_ms", decode.int)
      decode.success(types.TimeWindow(window_ms))
    }
    "user_stopped" -> decode.success(types.UserStopped)
    "budget_reached" -> {
      use budget <- decode.field("budget", decode.string)
      decode.success(types.BudgetReached(budget))
    }
    "agent_failure" -> {
      use node <- decode.field("node", decode.string)
      use reason <- decode.field("reason", decode.string)
      decode.success(types.AgentFailure(node, reason))
    }
    "legacy_unknown" -> decode.success(types.LegacyUnknown)
    _ -> decode.failure(types.LegacyUnknown, expected: "observation end")
  }
}

fn capture_issue_decoder() -> decode.Decoder(types.CaptureIssue) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "dropped_events" -> {
      use node <- decode.field("node", decode.string)
      use count <- decode.field("count", decode.int)
      decode.success(types.DroppedEvents(node, count))
    }
    "missing_node" -> {
      use node <- decode.field("node", decode.string)
      decode.success(types.MissingNode(node))
    }
    "batch_sequence_gap" -> {
      use node <- decode.field("node", decode.string)
      use expected <- decode.field("expected", decode.int)
      use actual <- decode.field("actual", decode.int)
      decode.success(types.BatchSequenceGap(node, expected, actual))
    }
    "duplicate_batch" -> {
      use node <- decode.field("node", decode.string)
      use sequence <- decode.field("sequence", decode.int)
      decode.success(types.DuplicateBatch(node, sequence))
    }
    "receipt_mismatch" -> {
      use node <- decode.field("node", decode.string)
      use field <- decode.field("field", decode.string)
      use expected <- decode.field("expected", decode.int)
      use actual <- decode.field("actual", decode.int)
      decode.success(types.ReceiptMismatch(node, field, expected, actual))
    }
    "drain_timeout" -> {
      use node <- decode.field("node", decode.string)
      use timeout <- decode.field("timeout_ms", decode.int)
      decode.success(types.DrainTimeout(node, timeout))
    }
    "legacy_unverified" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(types.LegacyUnverified(reason))
    }
    _ -> decode.failure(types.LegacyUnverified(""), expected: "capture issue")
  }
}

fn receipt_decoder() -> decode.Decoder(types.NodeReceipt) {
  use node <- decode.field("node", decode.string)
  use sequence <- decode.field("final_batch_sequence", decode.int)
  use events <- decode.field("event_count", decode.int)
  use bytes <- decode.field("byte_count", decode.int)
  decode.success(types.NodeReceipt(node, sequence, events, bytes))
}

fn legacy_outcome_decoder() -> decode.Decoder(types.CaptureOutcome) {
  use kind <- decode.field("kind", decode.string)
  let warning =
    types.LegacyUnverified(
      "v1 completeness and confidence were not delivery verified",
    )
  case kind {
    "complete" ->
      decode.success(types.CaptureOutcome(types.LegacyUnknown, [warning], []))
    "truncated" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(
        types.CaptureOutcome(types.BudgetReached(reason), [warning], []),
      )
    }
    "gapped" -> {
      use count <- decode.field("dropped_events", decode.int)
      decode.success(
        types.CaptureOutcome(
          types.LegacyUnknown,
          [
            types.LegacyUnverified(
              "v1 reported "
              <> int.to_string(count)
              <> " dropped events without node receipts",
            ),
            warning,
          ],
          [],
        ),
      )
    }
    "partial_node" -> {
      use nodes <- decode.field("missing_nodes", decode.list(decode.string))
      decode.success(
        types.CaptureOutcome(
          types.LegacyUnknown,
          [
            types.LegacyUnverified(
              "v1 reported missing nodes: " <> string.join(nodes, ","),
            ),
            warning,
          ],
          [],
        ),
      )
    }
    "inferred" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(
        types.CaptureOutcome(
          types.LegacyUnknown,
          [types.LegacyUnverified(reason), warning],
          [],
        ),
      )
    }
    _ ->
      decode.failure(
        types.CaptureOutcome(types.LegacyUnknown, [warning], []),
        expected: "legacy completeness",
      )
  }
}

/// Decode and validate one canonical bounded graph segment in O(v + e).
/// Invalid segment-local references, limits, versions, and byte representations
/// fail closed. Cross-segment endpoints are resolved against the complete event
/// set by the archive reader.
pub fn decode_graph_segment(
  source: String,
) -> Result(GraphSegment, CodecError) {
  case json.parse(source, versioned_graph_segment_decoder()) {
    Error(_) -> Error(InvalidJson("JSON does not match the expected schema"))
    Ok(GraphSegmentV2(segment)) ->
      case validate_graph_segment(segment) {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case encode_graph_segment(segment) == source {
            True -> Ok(segment)
            False -> Error(NonCanonicalJson)
          }
      }
    Ok(UnsupportedGraphSegment(version)) -> Error(UnknownSchemaVersion(version))
  }
}

fn graph_segment_decoder() -> decode.Decoder(GraphSegment) {
  use _version <- decode.field("schema_version", decode.int)
  use event_ids <- decode.field("event_ids", decode.list(decode.string))
  use edges <- decode.field("edges", decode.list(edge_decoder()))
  use boundaries <- decode.field("boundaries", decode.list(boundary_decoder()))
  decode.success(GraphSegment(event_ids, edges, boundaries))
}

fn edge_decoder() -> decode.Decoder(types.CausalEdge) {
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  use kind <- decode.field("kind", edge_kind_decoder())
  use evidence <- decode.field("evidence", evidence_decoder_v2())
  decode.success(types.CausalEdge(from, to, kind, evidence))
}

fn boundary_decoder() -> decode.Decoder(types.Boundary) {
  use event_id <- decode.field("event_id", decode.string)
  use kind <- decode.field("kind", edge_kind_decoder())
  use reason <- decode.field("reason", decode.string)
  decode.success(types.Boundary(event_id, kind, reason))
}

fn edge_kind_decoder() -> decode.Decoder(types.EdgeKind) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "sequential_message" -> {
      use serial <- decode.field("serial", serial_decoder())
      decode.success(types.SequentialMessage(serial))
    }
    "process_order" -> decode.success(types.ProcessOrder)
    "spawned" -> decode.success(types.Spawned)
    "link_relationship" -> decode.success(types.LinkRelationship)
    "inferred_relation" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(types.InferredRelation(reason))
    }
    "external_boundary" -> decode.success(types.ExternalBoundary)
    "unobserved_state" -> decode.success(types.UnobservedState)
    _ -> decode.failure(types.UnobservedState, expected: "edge kind")
  }
}

/// Decode and validate canonical clock calibration in O(nodes), preserving
/// uncertainty samples and rejecting invalid or non-canonical input.
pub fn decode_clocks(
  source: String,
) -> Result(types.ClockCalibration, CodecError) {
  case json.parse(source, versioned_clocks_decoder()) {
    Error(_) -> Error(InvalidJson("JSON does not match the expected schema"))
    Ok(ClocksV2(clocks)) ->
      case validate_clocks(clocks) {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case encode_clocks(clocks) == source {
            True -> Ok(clocks)
            False -> Error(NonCanonicalJson)
          }
      }
    Ok(UnsupportedClocks(version)) -> Error(UnknownSchemaVersion(version))
  }
}

fn clocks_decoder() -> decode.Decoder(types.ClockCalibration) {
  use _version <- decode.field("schema_version", decode.int)
  use anchor <- decode.field("capture_anchor_unix_ns", int_string_decoder())
  use nodes <- decode.field("nodes", decode.list(node_clock_decoder()))
  decode.success(types.ClockCalibration(anchor, nodes))
}

fn node_clock_decoder() -> decode.Decoder(types.NodeClock) {
  use node <- decode.field("node", decode.string)
  use origin <- decode.field("origin_local_ns", int_string_decoder())
  use before <- decode.field("before", decode.optional(clock_sample_decoder()))
  use after <- decode.field("after", decode.optional(clock_sample_decoder()))
  decode.success(types.NodeClock(node, origin, before, after))
}

fn clock_sample_decoder() -> decode.Decoder(types.ClockSample) {
  use local <- decode.field("local_ns", int_string_decoder())
  use unix <- decode.field("unix_midpoint_ns", int_string_decoder())
  use uncertainty <- decode.field("uncertainty_ns", decode.int)
  use rtt <- decode.field("rtt_ns", decode.int)
  decode.success(types.ClockSample(local, unix, uncertainty, rtt))
}

fn int_string_decoder() -> decode.Decoder(Int) {
  decode.then(decode.string, fn(source) {
    case int.parse(source) {
      Ok(value) -> decode.success(value)
      Error(_) -> decode.failure(0, expected: "decimal integer string")
    }
  })
}

fn privacy_decoder() -> decode.Decoder(types.Privacy) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "metadata" -> decode.success(types.Metadata)
    "raw" -> {
      use redact_keys <- decode.field("redact_keys", decode.list(decode.string))
      use max_depth <- decode.field("max_depth", decode.int)
      use max_binary_bytes <- decode.field("max_binary_bytes", decode.int)
      decode.success(
        types.Raw(types.RawPolicy(redact_keys, max_depth, max_binary_bytes)),
      )
    }
    _ -> decode.failure(types.Metadata, expected: "privacy policy")
  }
}

/// Validate a typed manifest without encoding and parsing it again.
pub fn validate_manifest(manifest: Manifest) -> Result(Nil, CodecError) {
  use Nil <- result_try(ensure(
    manifest.schema_version == 1 || manifest.schema_version == schema_version,
    "schema_version",
    "unsupported version",
  ))
  use Nil <- result_try(ensure(
    valid_text(manifest.tool_version, 64),
    "tool_version",
    "must be 1..64 bytes",
  ))
  use Nil <- result_try(ensure(
    valid_id(manifest.capture_id),
    "capture_id",
    "invalid identifier",
  ))
  use Nil <- result_try(ensure(
    manifest.nodes != [] && list.length(manifest.nodes) <= 32,
    "nodes",
    "must contain 1..32 nodes",
  ))
  use Nil <- result_try(ensure(
    all_unique(manifest.nodes) && list.all(manifest.nodes, valid_node),
    "nodes",
    "nodes must be unique and valid",
  ))
  use Nil <- result_try(validate_outcome(manifest.outcome))
  use Nil <- result_try(ensure(
    manifest.schema_version == 1
      || outcome_references_nodes(manifest.outcome, manifest.nodes),
    "outcome",
    "references a node not declared by the manifest",
  ))
  validate_privacy(manifest.privacy)
}

fn outcome_references_nodes(
  outcome: types.CaptureOutcome,
  nodes: List(String),
) -> Bool {
  let end_valid = case outcome.end {
    types.AgentFailure(node, _) -> list.contains(nodes, node)
    _ -> True
  }
  end_valid
  && list.all(outcome.receipts, fn(receipt) {
    list.contains(nodes, receipt.node)
  })
  && list.all(outcome.issues, fn(issue) {
    case issue {
      types.DroppedEvents(node, _)
      | types.MissingNode(node)
      | types.BatchSequenceGap(node, _, _)
      | types.DuplicateBatch(node, _)
      | types.ReceiptMismatch(node, _, _, _)
      | types.DrainTimeout(node, _) -> list.contains(nodes, node)
      types.LegacyUnverified(_) -> True
    }
  })
}

/// Validate a typed schema-v2 event without a JSON round trip.
pub fn validate_event(event: types.TraceEvent) -> Result(Nil, CodecError) {
  use Nil <- result_try(validate_event_identity(event))
  use Nil <- result_try(ensure(
    event.local_instant.offset_ns >= 0
      && event.local_instant.offset_ns <= 9_007_199_254_740_991,
    "local_instant.offset_ns",
    "must be a non-negative JavaScript-safe relative value",
  ))
  use Nil <- result_try(ensure(
    event.local_instant.order >= 0
      && event.local_instant.order <= 9_007_199_254_740_991,
    "local_instant.order",
    "must be a non-negative JavaScript-safe order",
  ))
  use Nil <- result_try(validate_kind(event.kind))
  validate_evidence(event.evidence)
}

fn validate_legacy_event(event: types.TraceEvent) -> Result(Nil, CodecError) {
  use Nil <- result_try(validate_event_identity(event))
  use Nil <- result_try(validate_kind(event.kind))
  validate_evidence(event.evidence)
}

fn validate_event_identity(event: types.TraceEvent) -> Result(Nil, CodecError) {
  use Nil <- result_try(ensure(valid_id(event.id), "id", "invalid event id"))
  use Nil <- result_try(ensure(
    valid_id(event.root_id),
    "root_id",
    "invalid root id",
  ))
  use Nil <- result_try(ensure(valid_node(event.node), "node", "invalid node"))
  use Nil <- result_try(validate_process_ref(event.process.physical))
  use Nil <- result_try(ensure(
    event.process.physical.node == event.node,
    "process.physical.node",
    "must match the observing event node",
  ))
  use Nil <- result_try(case event.process.logical {
    Some(actor) ->
      ensure(
        valid_id(actor.id) && valid_text(actor.label, 256),
        "process.logical",
        "invalid logical actor",
      )
    None -> Ok(Nil)
  })
  use Nil <- result_try(ensure(
    list.length(event.process.evidence) <= 64,
    "process.identity_evidence",
    "too many entries",
  ))
  validate_identity_evidence(event.process.evidence)
}

fn validate_identity_evidence(
  evidence: List(types.IdentityEvidence),
) -> Result(Nil, CodecError) {
  case evidence {
    [] -> Ok(Nil)
    [item, ..rest] -> {
      use Nil <- result_try(case item {
        types.RegisteredName(value)
        | types.ProcessLabel(value)
        | types.Ancestor(value)
        | types.SupervisorChildId(value) ->
          ensure(
            valid_text(value, 256),
            "process.identity_evidence",
            "invalid identity value",
          )
        types.InitialCall(mfa) -> validate_mfa(mfa)
        types.RestartProximity(milliseconds) ->
          ensure(
            milliseconds >= 0 && safe_integer(milliseconds),
            "process.identity_evidence",
            "invalid restart proximity",
          )
      })
      validate_identity_evidence(rest)
    }
  }
}

fn validate_kind(kind: types.TraceEventKind) -> Result(Nil, CodecError) {
  case kind {
    types.Root(mfa, arguments) -> {
      use Nil <- result_try(validate_mfa(mfa))
      use Nil <- result_try(ensure(
        list.length(arguments) <= 1024,
        "event.arguments",
        "too many arguments",
      ))
      validate_terms(arguments, 0)
    }
    types.Send(peer, message, serial) | types.Received(peer, message, serial) -> {
      use Nil <- result_try(validate_process_ref(peer))
      use Nil <- result_try(validate_serial(serial))
      validate_term(message, 0)
    }
    types.Spawn(child, mfa) -> {
      use Nil <- result_try(validate_process_ref(child))
      validate_mfa(mfa)
    }
    types.Exit(reason) -> validate_term(reason, 0)
    types.Register(name) ->
      ensure(valid_text(name, 255), "event.name", "invalid registered name")
    types.Link(peer) -> validate_process_ref(peer)
    types.Metric(name, _) ->
      ensure(valid_text(name, 255), "event.name", "invalid metric name")
    types.SystemSignal(name, value) ->
      ensure(
        valid_text(name, 255) && safe_integer(value),
        "event.name",
        "invalid signal name or value",
      )
    types.Gap(count, reason) -> {
      use Nil <- result_try(ensure(
        count > 0 && safe_integer(count),
        "event.dropped_events",
        "must be positive",
      ))
      ensure(valid_text(reason, 1024), "event.reason", "invalid reason")
    }
    types.Stop(reason) ->
      ensure(valid_text(reason, 1024), "event.reason", "invalid reason")
  }
}

fn validate_serial(serial: types.SequenceSerial) -> Result(Nil, CodecError) {
  let #(previous, current) = case serial {
    types.SequenceSerial(previous, current) -> #(previous, current)
    types.LegacySerial(current) -> #(0, current)
  }
  ensure(
    previous >= 0
      && current >= 0
      && previous <= 9_007_199_254_740_991
      && current <= 9_007_199_254_740_991,
    "event.serial",
    "serial counters must be non-negative JavaScript-safe integers",
  )
}

fn validate_mfa(mfa: types.Mfa) -> Result(Nil, CodecError) {
  ensure(
    valid_text(mfa.module_, 255)
      && valid_text(mfa.function_, 255)
      && mfa.arity >= 0
      && mfa.arity <= 255,
    "mfa",
    "invalid module, function, or arity",
  )
}

fn validate_process_ref(process: types.ProcessRef) -> Result(Nil, CodecError) {
  ensure(
    valid_node(process.node) && valid_text(process.pid, 255),
    "process_ref",
    "invalid node or pid",
  )
}

fn validate_terms(
  terms: List(types.TermView),
  depth: Int,
) -> Result(Nil, CodecError) {
  case terms {
    [] -> Ok(Nil)
    [term, ..rest] -> {
      use Nil <- result_try(validate_term(term, depth))
      validate_terms(rest, depth)
    }
  }
}

fn validate_term(term: types.TermView, depth: Int) -> Result(Nil, CodecError) {
  case depth > 64 {
    True -> Error(InvalidField("term", "maximum depth exceeded"))
    False ->
      case term {
        types.Hidden -> Ok(Nil)
        types.Atom(name) | types.Tag(name) | types.Redacted(name) ->
          ensure(valid_text(name, 1024), "term", "invalid text")
        types.Tuple(items) | types.Constructor(_, items) -> {
          use Nil <- result_try(ensure(
            list.length(items) <= 1024,
            "term.items",
            "collection limit exceeded",
          ))
          validate_terms(items, depth + 1)
        }
        types.ListView(length, items) -> {
          use Nil <- result_try(ensure(
            length >= list.length(items)
              && length <= 1_000_000
              && list.length(items) <= 1024,
            "term.list",
            "invalid declared or materialized length",
          ))
          validate_terms(items, depth + 1)
        }
        types.MapView(size, entries) -> {
          use Nil <- result_try(ensure(
            size >= list.length(entries)
              && size <= 1_000_000
              && list.length(entries) <= 1024,
            "term.map",
            "invalid declared or materialized size",
          ))
          validate_entries(entries, depth + 1)
        }
        types.BinaryMetadata(bytes, display, fingerprint) ->
          validate_scalar_metadata(bytes, display, fingerprint)
        types.Scalar(kind, display, fingerprint) -> {
          use Nil <- result_try(ensure(
            valid_text(kind, 64),
            "term.scalar_kind",
            "invalid scalar kind",
          ))
          validate_scalar_metadata(0, display, fingerprint)
        }
      }
  }
}

fn validate_entries(
  entries: List(#(types.TermView, types.TermView)),
  depth: Int,
) -> Result(Nil, CodecError) {
  case entries {
    [] -> Ok(Nil)
    [entry, ..rest] -> {
      use Nil <- result_try(validate_term(entry.0, depth))
      use Nil <- result_try(validate_term(entry.1, depth))
      validate_entries(rest, depth)
    }
  }
}

fn validate_scalar_metadata(
  bytes: Int,
  display: Option(String),
  fingerprint: Option(String),
) -> Result(Nil, CodecError) {
  use Nil <- result_try(ensure(
    bytes >= 0 && safe_integer(bytes),
    "term.bytes",
    "must be a non-negative JavaScript-safe integer",
  ))
  use Nil <- result_try(case display {
    Some(value) ->
      ensure(
        string.byte_size(value) <= 1_048_576,
        "term.display",
        "display limit exceeded",
      )
    None -> Ok(Nil)
  })
  case fingerprint {
    Some(value) ->
      ensure(
        string.byte_size(value) <= 128,
        "term.fingerprint",
        "fingerprint limit exceeded",
      )
    None -> Ok(Nil)
  }
}

fn validate_evidence(evidence: types.Evidence) -> Result(Nil, CodecError) {
  case evidence {
    types.Exact -> Ok(Nil)
    types.Inferred(inference) -> {
      use Nil <- result_try(ensure(
        valid_text(inference.method, 128),
        "evidence.method",
        "invalid method",
      ))
      use Nil <- result_try(ensure(
        valid_text(inference.reason, 2048),
        "evidence.reason",
        "invalid reason",
      ))
      use Nil <- result_try(ensure(
        list.length(inference.inputs) <= 256,
        "evidence.inputs",
        "too many inputs",
      ))
      validate_inference_inputs(inference.inputs)
    }
  }
}

fn validate_inference_inputs(
  inputs: List(types.InferenceInput),
) -> Result(Nil, CodecError) {
  case inputs {
    [] -> Ok(Nil)
    [input, ..rest] -> {
      use Nil <- result_try(case input {
        types.EvidenceEvent(id) ->
          ensure(valid_id(id), "evidence.inputs.event", "invalid event id")
        types.ObservedValue(name, value) ->
          ensure(
            valid_text(name, 128) && valid_text(value, 2048),
            "evidence.inputs.observed",
            "invalid observation",
          )
        types.AlgorithmSetting(name, value) ->
          ensure(
            valid_text(name, 128) && valid_text(value, 2048),
            "evidence.inputs.setting",
            "invalid algorithm setting",
          )
      })
      validate_inference_inputs(rest)
    }
  }
}

fn validate_outcome(outcome: types.CaptureOutcome) -> Result(Nil, CodecError) {
  use Nil <- result_try(validate_observation_end(outcome.end))
  use Nil <- result_try(ensure(
    list.length(outcome.issues) <= 10_000,
    "outcome.issues",
    "too many issues",
  ))
  use Nil <- result_try(ensure(
    list.length(outcome.receipts) <= 32,
    "outcome.receipts",
    "too many receipts",
  ))
  let nodes = list.map(outcome.receipts, fn(receipt) { receipt.node })
  use Nil <- result_try(ensure(
    all_unique(nodes),
    "outcome.receipts",
    "duplicate node receipt",
  ))
  use Nil <- result_try(validate_issues(outcome.issues))
  validate_receipts(outcome.receipts)
}

fn validate_observation_end(
  end: types.ObservationEnd,
) -> Result(Nil, CodecError) {
  case end {
    types.QuietPeriod(milliseconds) | types.TimeWindow(milliseconds) ->
      ensure(
        milliseconds > 0 && safe_integer(milliseconds),
        "outcome.end",
        "invalid duration",
      )
    types.UserStopped | types.LegacyUnknown -> Ok(Nil)
    types.BudgetReached(budget) ->
      ensure(valid_text(budget, 128), "outcome.end", "invalid budget")
    types.AgentFailure(node, reason) ->
      ensure(
        valid_issue_node(node) && valid_text(reason, 1024),
        "outcome.end",
        "invalid agent failure",
      )
  }
}

fn validate_issues(
  issues: List(types.CaptureIssue),
) -> Result(Nil, CodecError) {
  case issues {
    [] -> Ok(Nil)
    [issue, ..rest] -> {
      use Nil <- result_try(case issue {
        types.DroppedEvents(node, count) ->
          ensure(
            valid_issue_node(node) && count > 0 && safe_integer(count),
            "outcome.issue",
            "invalid dropped event count",
          )
        types.MissingNode(node) ->
          ensure(
            valid_issue_node(node),
            "outcome.issue",
            "invalid missing node",
          )
        types.BatchSequenceGap(node, expected, actual) ->
          ensure(
            valid_issue_node(node)
              && expected > 0
              && actual > expected
              && safe_integer(actual),
            "outcome.issue",
            "invalid batch sequence gap",
          )
        types.DuplicateBatch(node, sequence) ->
          ensure(
            valid_issue_node(node) && sequence > 0 && safe_integer(sequence),
            "outcome.issue",
            "invalid duplicate batch sequence",
          )
        types.ReceiptMismatch(node, field, expected, actual) ->
          ensure(
            valid_issue_node(node)
              && list.contains(
              ["final_batch_sequence", "event_count", "byte_count"],
              field,
            )
              && expected >= 0
              && actual >= 0
              && safe_integer(expected)
              && safe_integer(actual),
            "outcome.issue",
            "invalid receipt mismatch",
          )
        types.DrainTimeout(node, timeout_ms) ->
          ensure(
            valid_issue_node(node) && timeout_ms >= 1000 && timeout_ms <= 60_000,
            "outcome.issue",
            "invalid drain timeout",
          )
        types.LegacyUnverified(reason) ->
          ensure(
            valid_text(reason, 2048),
            "outcome.issue",
            "invalid legacy warning",
          )
      })
      validate_issues(rest)
    }
  }
}

fn validate_receipts(
  receipts: List(types.NodeReceipt),
) -> Result(Nil, CodecError) {
  case receipts {
    [] -> Ok(Nil)
    [receipt, ..rest] -> {
      use Nil <- result_try(ensure(
        valid_node(receipt.node)
          && receipt.final_batch_sequence >= 0
          && receipt.event_count >= 0
          && receipt.byte_count >= 0
          && safe_integer(receipt.final_batch_sequence)
          && safe_integer(receipt.event_count)
          && safe_integer(receipt.byte_count),
        "outcome.receipt",
        "invalid receipt",
      ))
      validate_receipts(rest)
    }
  }
}

fn validate_privacy(privacy: types.Privacy) -> Result(Nil, CodecError) {
  case privacy {
    types.Metadata -> Ok(Nil)
    types.Raw(policy) ->
      ensure(
        policy.redact_keys != []
          && list.length(policy.redact_keys) <= 128
          && all_unique(policy.redact_keys)
          && list.all(policy.redact_keys, fn(key) { valid_text(key, 256) })
          && policy.max_depth > 0
          && policy.max_depth <= 32
          && policy.max_binary_bytes > 0
          && policy.max_binary_bytes <= 1_048_576,
        "privacy",
        "invalid raw policy",
      )
  }
}

/// Validate a typed schema-v2 graph segment without a JSON round trip.
///
/// A cross-segment edge may name one event from an adjacent segment, so at
/// least one endpoint must belong to this segment. Archive readers validate
/// the other endpoint against the complete event set.
pub fn validate_graph_segment(
  segment: GraphSegment,
) -> Result(Nil, CodecError) {
  use Nil <- result_try(ensure(
    list.length(segment.event_ids) <= 1000
      && all_unique(segment.event_ids)
      && list.all(segment.event_ids, valid_id)
      && list.length(segment.edges) <= 10_000
      && list.length(segment.boundaries) <= 10_000,
    "graph",
    "segment collection limit exceeded",
  ))
  let event_ids =
    segment.event_ids
    |> list.map(fn(event_id) { #(event_id, Nil) })
    |> dict.from_list
  use Nil <- result_try(validate_edges(segment.edges, event_ids))
  validate_boundaries(segment.boundaries, event_ids)
}

fn validate_edges(
  edges: List(types.CausalEdge),
  event_ids: Dict(String, Nil),
) -> Result(Nil, CodecError) {
  case edges {
    [] -> Ok(Nil)
    [edge, ..rest] -> {
      let has_local_endpoint =
        dict.has_key(event_ids, edge.from) || dict.has_key(event_ids, edge.to)
      use Nil <- result_try(ensure(
        valid_id(edge.from)
          && valid_id(edge.to)
          && edge.from != edge.to
          && has_local_endpoint,
        "graph.edge",
        "invalid edge reference",
      ))
      use Nil <- result_try(validate_edge_kind(edge.kind))
      use Nil <- result_try(validate_evidence(edge.evidence))
      validate_edges(rest, event_ids)
    }
  }
}

fn validate_edge_kind(kind: types.EdgeKind) -> Result(Nil, CodecError) {
  case kind {
    types.SequentialMessage(serial) -> validate_serial(serial)
    types.InferredRelation(reason) ->
      ensure(valid_text(reason, 2048), "graph.edge.kind", "invalid reason")
    types.ProcessOrder
    | types.Spawned
    | types.LinkRelationship
    | types.ExternalBoundary
    | types.UnobservedState -> Ok(Nil)
  }
}

fn validate_boundaries(
  boundaries: List(types.Boundary),
  event_ids: Dict(String, Nil),
) -> Result(Nil, CodecError) {
  case boundaries {
    [] -> Ok(Nil)
    [boundary, ..rest] -> {
      use Nil <- result_try(ensure(
        valid_id(boundary.event_id)
          && dict.has_key(event_ids, boundary.event_id)
          && valid_text(boundary.reason, 2048),
        "graph.boundary",
        "invalid boundary",
      ))
      use Nil <- result_try(validate_edge_kind(boundary.kind))
      validate_boundaries(rest, event_ids)
    }
  }
}

/// Validate typed clock calibration without a JSON round trip.
pub fn validate_clocks(
  calibration: types.ClockCalibration,
) -> Result(Nil, CodecError) {
  use Nil <- result_try(ensure(
    calibration.capture_anchor_unix_ns >= 0
      && signed_64(calibration.capture_anchor_unix_ns),
    "clocks.capture_anchor_unix_ns",
    "invalid Unix anchor",
  ))
  let nodes = list.map(calibration.nodes, fn(clock) { clock.node })
  use Nil <- result_try(ensure(
    list.length(nodes) <= 32 && all_unique(nodes),
    "clocks.nodes",
    "too many or duplicate nodes",
  ))
  validate_node_clocks(calibration.nodes)
}

fn validate_node_clocks(
  clocks: List(types.NodeClock),
) -> Result(Nil, CodecError) {
  case clocks {
    [] -> Ok(Nil)
    [clock, ..rest] -> {
      use Nil <- result_try(ensure(
        valid_node(clock.node) && signed_64(clock.origin_local_ns),
        "clocks.node",
        "invalid node or local origin",
      ))
      use Nil <- result_try(validate_optional_sample(clock.before))
      use Nil <- result_try(validate_optional_sample(clock.after))
      use Nil <- result_try(case clock.before, clock.after {
        Some(before), Some(after) ->
          ensure(
            before.local_ns < after.local_ns,
            "clocks.samples",
            "after probe must follow before probe in node-local time",
          )
        _, _ -> Ok(Nil)
      })
      validate_node_clocks(rest)
    }
  }
}

fn validate_optional_sample(
  sample: Option(types.ClockSample),
) -> Result(Nil, CodecError) {
  case sample {
    None -> Ok(Nil)
    Some(sample) ->
      ensure(
        signed_64(sample.local_ns)
          && sample.unix_midpoint_ns > 0
          && signed_64(sample.unix_midpoint_ns)
          && sample.uncertainty_ns >= 0
          && sample.rtt_ns >= 0
          && sample.uncertainty_ns <= sample.rtt_ns
          && safe_integer(sample.uncertainty_ns)
          && safe_integer(sample.rtt_ns),
        "clocks.sample",
        "invalid RTT bounds",
      )
  }
}

fn valid_id(value: String) -> Bool {
  valid_text(value, 256)
}

fn valid_node(value: String) -> Bool {
  case string.split(value, "@") {
    [name, host] -> valid_text(name, 127) && valid_text(host, 127)
    _ -> False
  }
}

fn valid_issue_node(value: String) -> Bool {
  valid_node(value)
}

fn valid_text(value: String, maximum: Int) -> Bool {
  let size = string.byte_size(value)
  size > 0 && size <= maximum && !string.contains(value, "\u{0}")
}

fn safe_integer(value: Int) -> Bool {
  value >= -9_007_199_254_740_991 && value <= 9_007_199_254_740_991
}

fn signed_64(value: Int) -> Bool {
  let source = int.to_string(value)
  case string.starts_with(source, "-") {
    True -> decimal_at_most(string.drop_start(source, 1), "9223372036854775808")
    False -> decimal_at_most(source, "9223372036854775807")
  }
}

fn decimal_at_most(source: String, maximum: String) -> Bool {
  case string.byte_size(source), string.byte_size(maximum) {
    size, maximum_size if size < maximum_size -> True
    size, maximum_size if size == maximum_size ->
      string.compare(source, maximum) != order.Gt
    _, _ -> False
  }
}

fn all_unique(values: List(String)) -> Bool {
  case values {
    [] -> True
    [value, ..rest] -> !list.contains(rest, value) && all_unique(rest)
  }
}

fn ensure(
  condition: Bool,
  field: String,
  reason: String,
) -> Result(Nil, CodecError) {
  case condition {
    True -> Ok(Nil)
    False -> Error(InvalidField(field, reason))
  }
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn result_replace(result: Result(Nil, e), value: a) -> Result(a, e) {
  case result {
    Ok(Nil) -> Ok(value)
    Error(error) -> Error(error)
  }
}
