// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/types
import beamtrace_runtime/raw_grant
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type BatchPrivacy {
  MetadataBatch
  RawBatch(grant: String, policy: types.RawPolicy)
}

pub type Batch {
  Batch(
    mode: String,
    event_count: Int,
    canonical: String,
    privacy: BatchPrivacy,
  )
}

pub fn encode(
  mode: String,
  events: List(types.TraceEvent),
) -> Result(String, String) {
  case valid_mode_and_size(mode, events) {
    Error(error) -> Error(error)
    Ok(Nil) -> {
      use Nil <- result_try(validate_metadata_events(events))
      Ok(metadata_canonical(mode, events))
    }
  }
}

pub fn encode_raw(
  mode: String,
  grant: String,
  requested_policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> Result(String, String) {
  let policy = raw_grant.normalize_policy(requested_policy)
  case
    valid_mode_and_size(mode, events),
    raw_grant.valid_token(grant),
    valid_raw_policy(policy)
  {
    Error(error), _, _ -> Error(error)
    _, False, _ -> Error("invalid_raw_capture_grant")
    _, _, False -> Error("invalid_raw_policy")
    Ok(Nil), True, True -> {
      use Nil <- result_try(validate_raw_events(events, policy))
      Ok(raw_transport(mode, grant, policy, events))
    }
  }
}

/// Decode the public metadata boundary. Raw payloads are deliberately denied
/// here so callers cannot opt into raw handling by accident.
pub fn decode(source: String) -> Result(Batch, String) {
  case raw_privacy(source) {
    True -> Error("raw_capture_not_authorized")
    False -> {
      use parts <- result_try(decode_batch_parts(source))
      let #(mode, privacy, _, _, _, _, encoded_events) = parts
      case privacy {
        "metadata" -> finish_metadata(mode, encoded_events)
        _ -> Error("invalid_payload")
      }
    }
  }
}

/// Decode the authenticated team-ingest boundary. Grant reservation still
/// happens separately and atomically before the canonical payload is stored.
pub fn decode_for_ingest(source: String) -> Result(Batch, String) {
  use parts <- result_try(decode_batch_parts(source))
  let #(
    mode,
    privacy,
    grant,
    redact_keys,
    max_depth,
    max_binary_bytes,
    encoded_events,
  ) = parts
  case privacy {
    "metadata" -> finish_metadata(mode, encoded_events)
    "raw" -> {
      let presented_policy =
        types.RawPolicy(redact_keys, max_depth, max_binary_bytes)
      let policy = raw_grant.normalize_policy(presented_policy)
      case
        raw_grant.valid_token(grant),
        policy == presented_policy,
        valid_raw_policy(policy)
      {
        False, _, _ -> Error("raw_capture_grant_denied")
        _, False, _ | _, _, False -> Error("invalid_raw_policy")
        True, True, True -> {
          use events <- result_try(decode_events(encoded_events, []))
          use Nil <- result_try(validate_raw_events(events, policy))
          Ok(Batch(
            mode: mode,
            event_count: list.length(events),
            canonical: raw_canonical(mode, policy, events),
            privacy: RawBatch(grant, policy),
          ))
        }
      }
    }
    _ -> Error("invalid_payload")
  }
}

fn finish_metadata(
  mode: String,
  encoded_events: List(String),
) -> Result(Batch, String) {
  use events <- result_try(decode_events(encoded_events, []))
  use Nil <- result_try(validate_metadata_events(events))
  Ok(Batch(
    mode: mode,
    event_count: list.length(events),
    canonical: metadata_canonical(mode, events),
    privacy: MetadataBatch,
  ))
}

fn valid_mode_and_size(
  mode: String,
  events: List(types.TraceEvent),
) -> Result(Nil, String) {
  case list.contains(["exact", "live"], mode), list.length(events) <= 128 {
    False, _ -> Error("invalid_payload")
    _, False -> Error("batch_event_limit")
    True, True -> Ok(Nil)
  }
}

fn decode_events(
  sources: List(String),
  accumulator: List(types.TraceEvent),
) -> Result(List(types.TraceEvent), String) {
  case sources {
    [] -> Ok(list.reverse(accumulator))
    [source, ..rest] ->
      case codec.decode_event(source) {
        Error(_) -> Error("invalid_payload")
        Ok(event) -> decode_events(rest, [event, ..accumulator])
      }
  }
}

fn validate_metadata_events(
  events: List(types.TraceEvent),
) -> Result(Nil, String) {
  case events {
    [] -> Ok(Nil)
    [event, ..rest] -> {
      use Nil <- result_try(validate_metadata_kind(event.kind))
      validate_metadata_events(rest)
    }
  }
}

fn validate_metadata_kind(kind: types.TraceEventKind) -> Result(Nil, String) {
  case kind {
    types.Root(_, arguments) -> validate_metadata_terms(arguments)
    types.Send(_, message, _) | types.Received(_, message, _) ->
      validate_metadata_term(message)
    types.Exit(reason) -> validate_metadata_term(reason)
    types.Spawn(_, _)
    | types.Register(_)
    | types.Link(_)
    | types.Metric(_, _)
    | types.SystemSignal(_, _)
    | types.Gap(_, _)
    | types.Stop(_) -> Ok(Nil)
  }
}

fn validate_metadata_terms(terms: List(types.TermView)) -> Result(Nil, String) {
  case terms {
    [] -> Ok(Nil)
    [term, ..rest] -> {
      use Nil <- result_try(validate_metadata_term(term))
      validate_metadata_terms(rest)
    }
  }
}

fn validate_metadata_term(term: types.TermView) -> Result(Nil, String) {
  case term {
    types.Scalar(_, Some(_), _) | types.BinaryMetadata(_, Some(_), _) ->
      Error("metadata_value_forbidden")
    types.Scalar(_, None, fingerprint)
    | types.BinaryMetadata(_, None, fingerprint) ->
      validate_fingerprint(fingerprint, "invalid_metadata_fingerprint")
    types.Tuple(items)
    | types.Constructor(_, items)
    | types.ListView(_, items) -> validate_metadata_terms(items)
    types.MapView(_, entries) -> validate_metadata_entries(entries)
    types.Hidden | types.Atom(_) | types.Tag(_) | types.Redacted(_) -> Ok(Nil)
  }
}

fn validate_metadata_entries(
  entries: List(#(types.TermView, types.TermView)),
) -> Result(Nil, String) {
  case entries {
    [] -> Ok(Nil)
    [#(key, value), ..rest] -> {
      use Nil <- result_try(validate_metadata_term(key))
      use Nil <- result_try(validate_metadata_term(value))
      validate_metadata_entries(rest)
    }
  }
}

fn validate_raw_events(
  events: List(types.TraceEvent),
  policy: types.RawPolicy,
) -> Result(Nil, String) {
  case events {
    [] -> Ok(Nil)
    [event, ..rest] -> {
      use Nil <- result_try(validate_raw_kind(event.kind, policy))
      validate_raw_events(rest, policy)
    }
  }
}

fn validate_raw_kind(
  kind: types.TraceEventKind,
  policy: types.RawPolicy,
) -> Result(Nil, String) {
  case kind {
    types.Root(_, arguments) -> validate_raw_terms(arguments, policy, 0)
    types.Send(_, message, _) | types.Received(_, message, _) ->
      validate_raw_term(message, policy, 0)
    types.Exit(reason) -> validate_raw_term(reason, policy, 0)
    types.Spawn(_, _)
    | types.Register(_)
    | types.Link(_)
    | types.Metric(_, _)
    | types.SystemSignal(_, _)
    | types.Gap(_, _)
    | types.Stop(_) -> Ok(Nil)
  }
}

fn validate_raw_terms(
  terms: List(types.TermView),
  policy: types.RawPolicy,
  depth: Int,
) -> Result(Nil, String) {
  case list.length(terms) <= 32, terms {
    False, _ -> Error("raw_item_limit")
    True, [] -> Ok(Nil)
    True, [term, ..rest] -> {
      use Nil <- result_try(validate_raw_term(term, policy, depth))
      validate_raw_terms(rest, policy, depth)
    }
  }
}

fn validate_raw_term(
  term: types.TermView,
  policy: types.RawPolicy,
  depth: Int,
) -> Result(Nil, String) {
  case depth > policy.max_depth, term {
    True, types.Redacted(_) -> Ok(Nil)
    True, _ -> Error("raw_depth_exceeded")
    False, types.Scalar(kind, Some(display), fingerprint) ->
      case valid_text(kind, 128) && valid_body(display, 4096) {
        False -> Error("invalid_raw_value")
        True -> validate_fingerprint(fingerprint, "invalid_raw_fingerprint")
      }
    False, types.BinaryMetadata(bytes, Some(display), fingerprint) ->
      case
        bytes >= 0,
        string.byte_size(display) <= policy.max_binary_bytes,
        valid_body(display, policy.max_binary_bytes)
      {
        True, True, True ->
          validate_fingerprint(fingerprint, "invalid_raw_fingerprint")
        _, _, _ -> Error("invalid_raw_value")
      }
    False, types.Scalar(_, None, _) | False, types.BinaryMetadata(_, None, _) ->
      Error("raw_value_required")
    False, types.Tuple(items) -> validate_raw_terms(items, policy, depth + 1)
    False, types.Constructor(name, items) -> {
      use Nil <- result_try(validate_name(name))
      validate_raw_terms(items, policy, depth + 1)
    }
    False, types.ListView(length, items) ->
      case length >= list.length(items) {
        False -> Error("invalid_raw_value")
        True -> validate_raw_terms(items, policy, depth + 1)
      }
    False, types.MapView(size, entries) ->
      case size >= list.length(entries) && list.length(entries) <= 32 {
        False -> Error("invalid_raw_value")
        True -> validate_raw_entries(entries, policy, depth + 1)
      }
    False, types.Atom(name) | False, types.Tag(name) -> validate_name(name)
    False, types.Redacted(reason) ->
      case valid_text(reason, 128) {
        True -> Ok(Nil)
        False -> Error("invalid_raw_value")
      }
    False, types.Hidden -> Ok(Nil)
  }
}

fn validate_raw_entries(
  entries: List(#(types.TermView, types.TermView)),
  policy: types.RawPolicy,
  depth: Int,
) -> Result(Nil, String) {
  case entries {
    [] -> Ok(Nil)
    [#(key, value), ..rest] -> {
      use Nil <- result_try(validate_raw_term(key, policy, depth))
      use Nil <- result_try(validate_redacted_value(key, value, policy, depth))
      validate_raw_entries(rest, policy, depth)
    }
  }
}

fn validate_redacted_value(
  key: types.TermView,
  value: types.TermView,
  policy: types.RawPolicy,
  depth: Int,
) -> Result(Nil, String) {
  case raw_key(key), value {
    Some(key), value ->
      case list.contains(policy.redact_keys, key), value {
        True, types.Redacted(_) -> validate_raw_term(value, policy, depth)
        True, _ -> Error("raw_redaction_required")
        False, _ -> validate_raw_term(value, policy, depth)
      }
    _, _ -> validate_raw_term(value, policy, depth)
  }
}

fn raw_key(term: types.TermView) -> Option(String) {
  case term {
    types.Atom(name) | types.Tag(name) -> Some(normalize_key(name))
    types.Scalar(_, Some(display), _)
    | types.BinaryMetadata(_, Some(display), _) -> Some(normalize_key(display))
    _ -> None
  }
}

fn normalize_key(value: String) -> String {
  value |> string.trim |> string.lowercase
}

fn validate_name(value: String) -> Result(Nil, String) {
  case valid_text(value, 4096) {
    True -> Ok(Nil)
    False -> Error("invalid_raw_value")
  }
}

fn valid_raw_policy(policy: types.RawPolicy) -> Bool {
  let normalized = raw_grant.normalize_policy(policy)
  normalized == policy
  && policy.redact_keys != []
  && list.length(policy.redact_keys) <= 128
  && list.all(policy.redact_keys, fn(key) { valid_text(key, 128) })
  && policy.max_depth > 0
  && policy.max_depth <= 32
  && policy.max_binary_bytes > 0
  && policy.max_binary_bytes <= 1_048_576
}

fn validate_fingerprint(
  fingerprint: Option(String),
  error: String,
) -> Result(Nil, String) {
  case fingerprint {
    Some(value) ->
      case
        string.length(value) == 64,
        string.lowercase(value) == value,
        bit_array.base16_decode(value)
      {
        True, True, Ok(bytes) ->
          case bit_array.byte_size(bytes) == 32 {
            True -> Ok(Nil)
            False -> Error(error)
          }
        _, _, _ -> Error(error)
      }
    None -> Error(error)
  }
}

fn valid_text(value: String, maximum_bytes: Int) -> Bool {
  let size = string.byte_size(value)
  size > 0
  && size <= maximum_bytes
  && !string.contains(value, "\u{0}")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn valid_body(value: String, maximum_bytes: Int) -> Bool {
  let size = string.byte_size(value)
  size > 0 && size <= maximum_bytes && !string.contains(value, "\u{0}")
}

fn metadata_canonical(mode: String, events: List(types.TraceEvent)) -> String {
  "{\"type\":\"batch\",\"mode\":\""
  <> mode
  <> "\",\"privacy\":\"metadata\",\"items\":["
  <> encoded_events(events)
  <> "]}"
}

fn raw_transport(
  mode: String,
  grant: String,
  policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> String {
  "{\"type\":\"batch\",\"mode\":\""
  <> mode
  <> "\",\"privacy\":\"raw\",\"grant\":\""
  <> grant
  <> "\",\"policy\":"
  <> raw_grant.canonical_policy(policy)
  <> ",\"items\":["
  <> encoded_events(events)
  <> "]}"
}

fn raw_canonical(
  mode: String,
  policy: types.RawPolicy,
  events: List(types.TraceEvent),
) -> String {
  "{\"type\":\"batch\",\"mode\":\""
  <> mode
  <> "\",\"privacy\":\"raw\",\"policy\":"
  <> raw_grant.canonical_policy(policy)
  <> ",\"items\":["
  <> encoded_events(events)
  <> "]}"
}

fn encoded_events(events: List(types.TraceEvent)) -> String {
  events |> list.map(codec.encode_event) |> string.join(",")
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

@external(erlang, "beamtrace_relay_payload_ffi", "decode_batch_parts")
fn decode_batch_parts(
  source: String,
) -> Result(
  #(String, String, String, List(String), Int, Int, List(String)),
  String,
)

@external(erlang, "beamtrace_relay_payload_ffi", "raw_privacy")
fn raw_privacy(source: String) -> Bool
