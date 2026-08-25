import beamtrace/types
import gleam/dynamic/decode
import gleam/json

pub const schema_version = 1

pub type Manifest {
  Manifest(
    schema_version: Int,
    tool_version: String,
    capture_id: String,
    nodes: List(String),
    completeness: types.Completeness,
    privacy: types.Privacy,
    checksums: List(#(String, String)),
  )
}

pub fn encode_event(event: types.TraceEvent) -> String {
  event_json(event) |> json.to_string
}

pub fn decode_event(source: String) {
  json.parse(source, trace_event_decoder())
}

pub fn encode_manifest(manifest: Manifest) -> String {
  json.object([
    #("schema_version", json.int(manifest.schema_version)),
    #("tool_version", json.string(manifest.tool_version)),
    #("capture_id", json.string(manifest.capture_id)),
    #("nodes", json.array(manifest.nodes, json.string)),
    #("completeness", completeness_json(manifest.completeness)),
    #("privacy", privacy_json(manifest.privacy)),
    #(
      "checksums",
      json.array(manifest.checksums, fn(checksum) {
        let #(path, sha256) = checksum
        json.object([
          #("path", json.string(path)),
          #("sha256", json.string(sha256)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

pub fn decode_manifest(source: String) {
  json.parse(source, manifest_decoder())
}

/// Encode a trace event as a JSON object for structured protocol consumers.
pub fn event_json(event: types.TraceEvent) -> json.Json {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("id", json.string(event.id)),
    #("root_id", json.string(event.root_id)),
    #("node", json.string(event.node)),
    #("process", process_identity_json(event.process)),
    #("local_timestamp_ns", json.int(event.local_timestamp_ns)),
    #("event", event_kind_json(event.kind)),
    #("evidence", evidence_json(event.evidence)),
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

fn evidence_json(evidence: types.Evidence) -> json.Json {
  case evidence {
    types.Exact -> json.object([#("kind", json.string("exact"))])
    types.Inferred(reason, confidence) ->
      json.object([
        #("kind", json.string("inferred")),
        #("reason", json.string(reason)),
        #("confidence", json.float(confidence)),
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
        #("serial", json.int(serial)),
      ])
    types.Received(from, message, serial) ->
      json.object([
        #("kind", json.string("receive")),
        #("from", process_ref_json(from)),
        #("message", term_json(message)),
        #("serial", json.int(serial)),
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

fn completeness_json(completeness: types.Completeness) -> json.Json {
  case completeness {
    types.Complete -> json.object([#("kind", json.string("complete"))])
    types.Truncated(reason) ->
      json.object([
        #("kind", json.string("truncated")),
        #("reason", json.string(reason)),
      ])
    types.Gapped(dropped_events) ->
      json.object([
        #("kind", json.string("gapped")),
        #("dropped_events", json.int(dropped_events)),
      ])
    types.PartialNode(nodes) ->
      json.object([
        #("kind", json.string("partial_node")),
        #("missing_nodes", json.array(nodes, json.string)),
      ])
    types.InferredCapture(reason) ->
      json.object([
        #("kind", json.string("inferred")),
        #("reason", json.string(reason)),
      ])
  }
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

fn manifest_decoder() -> decode.Decoder(Manifest) {
  use schema_version <- decode.field("schema_version", decode.int)
  use tool_version <- decode.field("tool_version", decode.string)
  use capture_id <- decode.field("capture_id", decode.string)
  use nodes <- decode.field("nodes", decode.list(decode.string))
  use completeness <- decode.field("completeness", completeness_decoder())
  use privacy <- decode.field("privacy", privacy_decoder())
  use checksums <- decode.field("checksums", decode.list(checksum_decoder()))
  decode.success(Manifest(
    schema_version,
    tool_version,
    capture_id,
    nodes,
    completeness,
    privacy,
    checksums,
  ))
}

fn checksum_decoder() -> decode.Decoder(#(String, String)) {
  use path <- decode.field("path", decode.string)
  use sha256 <- decode.field("sha256", decode.string)
  decode.success(#(path, sha256))
}

fn trace_event_decoder() -> decode.Decoder(types.TraceEvent) {
  use _version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use root_id <- decode.field("root_id", decode.string)
  use node <- decode.field("node", decode.string)
  use process <- decode.field("process", process_identity_decoder())
  use local_timestamp_ns <- decode.field("local_timestamp_ns", decode.int)
  use kind <- decode.field("event", event_kind_decoder())
  use evidence <- decode.field("evidence", evidence_decoder())
  decode.success(types.TraceEvent(
    id,
    root_id,
    node,
    process,
    local_timestamp_ns,
    kind,
    evidence,
  ))
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

fn evidence_decoder() -> decode.Decoder(types.Evidence) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "exact" -> decode.success(types.Exact)
    "inferred" -> {
      use reason <- decode.field("reason", decode.string)
      use confidence <- decode.field("confidence", decode.float)
      decode.success(types.inferred(reason, confidence))
    }
    _ -> decode.failure(types.Exact, expected: "evidence")
  }
}

fn event_kind_decoder() -> decode.Decoder(types.TraceEventKind) {
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
      use serial <- decode.field("serial", decode.int)
      decode.success(types.Send(to, message, serial))
    }
    "receive" -> {
      use from <- decode.field("from", process_ref_decoder())
      use message <- decode.field("message", term_decoder())
      use serial <- decode.field("serial", decode.int)
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

fn completeness_decoder() -> decode.Decoder(types.Completeness) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "complete" -> decode.success(types.Complete)
    "truncated" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(types.Truncated(reason))
    }
    "gapped" -> {
      use dropped <- decode.field("dropped_events", decode.int)
      decode.success(types.Gapped(dropped))
    }
    "partial_node" -> {
      use nodes <- decode.field("missing_nodes", decode.list(decode.string))
      decode.success(types.PartialNode(nodes))
    }
    "inferred" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(types.InferredCapture(reason))
    }
    _ -> decode.failure(types.Complete, expected: "capture completeness")
  }
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
