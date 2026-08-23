// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/types
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Batch {
  Batch(mode: String, event_count: Int, canonical: String)
}

pub fn encode(
  mode: String,
  events: List(types.TraceEvent),
) -> Result(String, String) {
  case list.contains(["exact", "live"], mode), list.length(events) <= 128 {
    False, _ -> Error("invalid_payload")
    _, False -> Error("batch_event_limit")
    True, True -> {
      use Nil <- result_try(validate_events(events))
      Ok(canonical(mode, events))
    }
  }
}

pub fn decode(source: String) -> Result(Batch, String) {
  case decode_batch_parts(source) {
    Error(reason) -> Error(reason)
    Ok(parts) -> {
      let #(mode, privacy, encoded_events) = parts
      case privacy {
        "raw" -> Error("raw_capture_not_authorized")
        "metadata" -> decode_events(encoded_events, [])
        _ -> Error("invalid_payload")
      }
      |> then(fn(events) {
        use Nil <- result_try(validate_events(events))
        Ok(Batch(
          mode: mode,
          event_count: list.length(events),
          canonical: canonical(mode, events),
        ))
      })
    }
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

fn validate_events(events: List(types.TraceEvent)) -> Result(Nil, String) {
  case events {
    [] -> Ok(Nil)
    [event, ..rest] -> {
      use Nil <- result_try(validate_kind(event.kind))
      validate_events(rest)
    }
  }
}

fn validate_kind(kind: types.TraceEventKind) -> Result(Nil, String) {
  case kind {
    types.Root(_, arguments) -> validate_terms(arguments)
    types.Send(_, message, _) | types.Received(_, message, _) ->
      validate_term(message)
    types.Exit(reason) -> validate_term(reason)
    types.Spawn(_, _)
    | types.Register(_)
    | types.Link(_)
    | types.Metric(_, _)
    | types.SystemSignal(_, _)
    | types.Gap(_, _)
    | types.Stop(_) -> Ok(Nil)
  }
}

fn validate_terms(terms: List(types.TermView)) -> Result(Nil, String) {
  case terms {
    [] -> Ok(Nil)
    [term, ..rest] -> {
      use Nil <- result_try(validate_term(term))
      validate_terms(rest)
    }
  }
}

fn validate_term(term: types.TermView) -> Result(Nil, String) {
  case term {
    types.Scalar(_, Some(_), _) | types.BinaryMetadata(_, Some(_), _) ->
      Error("metadata_value_forbidden")
    types.Scalar(_, None, fingerprint)
    | types.BinaryMetadata(_, None, fingerprint) ->
      validate_fingerprint(fingerprint)
    types.Tuple(items)
    | types.Constructor(_, items)
    | types.ListView(_, items) -> validate_terms(items)
    types.MapView(_, entries) -> validate_entries(entries)
    types.Hidden | types.Atom(_) | types.Tag(_) | types.Redacted(_) -> Ok(Nil)
  }
}

fn validate_entries(
  entries: List(#(types.TermView, types.TermView)),
) -> Result(Nil, String) {
  case entries {
    [] -> Ok(Nil)
    [#(key, value), ..rest] -> {
      use Nil <- result_try(validate_term(key))
      use Nil <- result_try(validate_term(value))
      validate_entries(rest)
    }
  }
}

fn validate_fingerprint(fingerprint: Option(String)) {
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
            False -> Error("invalid_metadata_fingerprint")
          }
        _, _, _ -> Error("invalid_metadata_fingerprint")
      }
    None -> Error("invalid_metadata_fingerprint")
  }
}

fn canonical(mode: String, events: List(types.TraceEvent)) -> String {
  "{\"type\":\"batch\",\"mode\":\""
  <> mode
  <> "\",\"privacy\":\"metadata\",\"items\":["
  <> { events |> list.map(codec.encode_event) |> string.join(",") }
  <> "]}"
}

fn then(result: Result(a, e), next: fn(a) -> Result(b, e)) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  then(result, next)
}

@external(erlang, "beamtrace_relay_payload_ffi", "decode_batch_parts")
fn decode_batch_parts(
  source: String,
) -> Result(#(String, String, List(String)), String)
