import beamtrace/codec
import beamtrace/types
import gleam/list
import gleam/string

pub type Archive {
  Archive(manifest: codec.Manifest, events: List(types.TraceEvent))
}

pub type EventWindow {
  EventWindow(
    events: List(types.TraceEvent),
    total: Int,
    start: Int,
    limit: Int,
  )
}

pub type StorageError {
  InvalidContainer
  UnsafeEntry(path: String)
  DuplicateEntry(path: String)
  ZipBomb
  ChecksumMismatch
  InvalidWindow
  InvalidSearch
  CodecError(message: String)
  IoError(message: String)
}

pub fn save(
  path: String,
  manifest: codec.Manifest,
  events: List(types.TraceEvent),
) -> Result(Nil, StorageError) {
  let manifest_json = codec.encode_manifest(manifest)
  let event_lines = list.map(events, codec.encode_event)
  write_container(path, manifest_json, event_lines)
  |> map_error(classify_error)
}

pub fn load(path: String) -> Result(Archive, StorageError) {
  use payload <- try_result(read_container(path) |> map_error(classify_error))
  let #(manifest_json, event_lines) = payload
  use manifest <- try_result(
    codec.decode_manifest(manifest_json)
    |> map_error(fn(error) { CodecError(string.inspect(error)) }),
  )
  use events <- try_result(decode_events(event_lines, []))
  Ok(Archive(manifest, events))
}

pub fn entries(path: String) -> Result(List(String), StorageError) {
  list_entries(path) |> map_error(classify_error)
}

pub fn window(
  path: String,
  start start: Int,
  limit limit: Int,
) -> Result(EventWindow, StorageError) {
  case start < 0 || limit < 1 || limit > 1000 {
    True -> Error(InvalidWindow)
    False ->
      case read_window(path, start, limit) {
        Error(reason) -> Error(classify_error(reason))
        Ok(payload) -> {
          let #(event_lines, total) = payload
          case decode_events(event_lines, []) {
            Error(error) -> Error(error)
            Ok(events) -> Ok(EventWindow(events, total, start, limit))
          }
        }
      }
  }
}

pub fn search(
  path: String,
  query: String,
  start start: Int,
  limit limit: Int,
) -> Result(EventWindow, StorageError) {
  let normalized = string.trim(query)
  case
    start < 0 || limit < 1 || limit > 1000,
    normalized == "" || string.byte_size(normalized) > 256
  {
    True, _ -> Error(InvalidWindow)
    _, True -> Error(InvalidSearch)
    False, False ->
      case search_archive(path, normalized, start, limit) {
        Error(reason) -> Error(classify_error(reason))
        Ok(payload) -> {
          let #(event_lines, total) = payload
          case decode_events(event_lines, []) {
            Error(error) -> Error(error)
            Ok(events) -> Ok(EventWindow(events, total, start, limit))
          }
        }
      }
  }
}

fn decode_events(
  lines: List(String),
  accumulator: List(types.TraceEvent),
) -> Result(List(types.TraceEvent), StorageError) {
  case lines {
    [] -> Ok(list.reverse(accumulator))
    [line, ..rest] ->
      case codec.decode_event(line) {
        Ok(event) -> decode_events(rest, [event, ..accumulator])
        Error(error) -> Error(CodecError(string.inspect(error)))
      }
  }
}

fn classify_error(reason: String) -> StorageError {
  case reason {
    "invalid_container" -> InvalidContainer
    "zip_bomb" -> ZipBomb
    "checksum_mismatch" -> ChecksumMismatch
    "invalid_window" -> InvalidWindow
    "invalid_search" -> InvalidSearch
    _ ->
      case string.starts_with(reason, "unsafe_entry:") {
        True -> UnsafeEntry(string.drop_start(reason, 13))
        False ->
          case string.starts_with(reason, "duplicate_entry:") {
            True -> DuplicateEntry(string.drop_start(reason, 16))
            False -> IoError(reason)
          }
      }
  }
}

fn try_result(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn map_error(result: Result(a, e), transform: fn(e) -> f) -> Result(a, f) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(transform(error))
  }
}

@external(erlang, "beamtrace_storage_ffi", "write_container")
fn write_container(
  path: String,
  manifest_json: String,
  event_lines: List(String),
) -> Result(Nil, String)

@external(erlang, "beamtrace_storage_ffi", "read_container")
fn read_container(path: String) -> Result(#(String, List(String)), String)

@external(erlang, "beamtrace_storage_ffi", "list_entries")
fn list_entries(path: String) -> Result(List(String), String)

@external(erlang, "beamtrace_storage_ffi", "read_window")
fn read_window(
  path: String,
  start: Int,
  limit: Int,
) -> Result(#(List(String), Int), String)

@external(erlang, "beamtrace_storage_ffi", "search_archive")
fn search_archive(
  path: String,
  query: String,
  start: Int,
  limit: Int,
) -> Result(#(List(String), Int), String)
