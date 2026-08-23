import beamtrace/types
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub type Fingerprint =
  fn(String) -> String

/// Shapes a term before it can leave the observed node.
///
/// Metadata mode never places a scalar value in `display`. Its salted
/// fingerprint is useful only for equality checks within one capture.
pub fn shape(
  term: types.RawTerm,
  privacy: types.Privacy,
  fingerprint: Fingerprint,
) {
  shape_at(term, privacy, fingerprint, 0)
}

fn shape_at(
  term: types.RawTerm,
  privacy: types.Privacy,
  fingerprint: Fingerprint,
  depth: Int,
) -> types.TermView {
  case privacy {
    types.Raw(policy) if depth > policy.max_depth ->
      types.Redacted("depth limit")
    _ ->
      case term {
        types.RawHidden -> types.Hidden
        types.RawAtom(name) -> types.Atom(name)
        types.RawInt(value) ->
          scalar("integer", int.to_string(value), privacy, fingerprint)
        types.RawFloat(value) ->
          scalar("float", float.to_string(value), privacy, fingerprint)
        types.RawString(value) -> scalar("string", value, privacy, fingerprint)
        types.RawBinary(value, bytes) ->
          binary(value, bytes, privacy, fingerprint)
        types.RawTuple(items) ->
          types.Tuple(
            list.map(items, fn(item) {
              shape_at(item, privacy, fingerprint, depth + 1)
            }),
          )
        types.RawConstructor(name, fields) ->
          types.Constructor(
            name,
            list.map(fields, fn(field) {
              shape_at(field, privacy, fingerprint, depth + 1)
            }),
          )
        types.RawList(items) ->
          types.ListView(
            list.length(items),
            list.map(items, fn(item) {
              shape_at(item, privacy, fingerprint, depth + 1)
            }),
          )
        types.RawMap(entries) ->
          types.MapView(
            list.length(entries),
            list.map(entries, fn(entry) {
              let #(key, value) = entry
              let key_view = shape_at(key, privacy, fingerprint, depth + 1)
              let value_view = case privacy {
                types.Raw(policy) ->
                  case redacted_key(key, policy.redact_keys) {
                    True -> types.Redacted("key policy")
                    False -> shape_at(value, privacy, fingerprint, depth + 1)
                  }
                _ -> shape_at(value, privacy, fingerprint, depth + 1)
              }
              #(key_view, value_view)
            }),
          )
      }
  }
}

fn scalar(
  kind: String,
  value: String,
  privacy: types.Privacy,
  fingerprint: Fingerprint,
) -> types.TermView {
  case privacy {
    types.Metadata -> types.Scalar(kind, None, Some(fingerprint(value)))
    types.Raw(_) -> types.Scalar(kind, Some(value), Some(fingerprint(value)))
  }
}

fn binary(
  value: String,
  bytes: Int,
  privacy: types.Privacy,
  fingerprint: Fingerprint,
) -> types.TermView {
  case privacy {
    types.Metadata ->
      types.BinaryMetadata(bytes, None, Some(fingerprint(value)))
    types.Raw(policy) -> {
      let shown = case bytes > policy.max_binary_bytes {
        True ->
          string.slice(value, at_index: 0, length: policy.max_binary_bytes)
        False -> value
      }
      types.BinaryMetadata(bytes, Some(shown), Some(fingerprint(value)))
    }
  }
}

fn redacted_key(term: types.RawTerm, configured: List(String)) -> Bool {
  case term {
    types.RawAtom(name) -> is_sensitive_name(name, configured)
    types.RawString(name) -> is_sensitive_name(name, configured)
    _ -> False
  }
}

fn is_sensitive_name(name: String, configured: List(String)) -> Bool {
  let normalized = string.lowercase(name)
  let defaults = [
    "authorization",
    "cookie",
    "password",
    "passwd",
    "secret",
    "token",
    "api_key",
    "apikey",
  ]
  list.contains(defaults, normalized)
  || list.any(configured, fn(key) { string.lowercase(key) == normalized })
}

/// Human-readable rendering used by text exports. It deliberately renders
/// fingerprints as a marker rather than exposing the digest or source value.
pub fn render(view: types.TermView) -> String {
  case view {
    types.Hidden -> "<hidden>"
    types.Atom(name) -> name
    types.Tag(name) -> name
    types.Tuple(items) -> "{" <> render_items(items) <> "}"
    types.Constructor(name, fields) ->
      name <> "(" <> render_items(fields) <> ")"
    types.ListView(length, _) -> "list[" <> int.to_string(length) <> "]"
    types.MapView(size, _) -> "map{" <> int.to_string(size) <> "}"
    types.BinaryMetadata(bytes, display, _) ->
      case display {
        Some(value) -> "binary(" <> int.to_string(bytes) <> "):" <> value
        None -> "binary(" <> int.to_string(bytes) <> "):<fingerprinted>"
      }
    types.Scalar(kind, display, _) ->
      case display {
        Some(value) -> kind <> ":" <> value
        None -> kind <> ":<fingerprinted>"
      }
    types.Redacted(reason) -> "<redacted:" <> reason <> ">"
  }
}

fn render_items(items: List(types.TermView)) -> String {
  items |> list.map(render) |> string.join(", ")
}
