// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/dag
import beamtrace/types
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

const segment_event_limit = 1000

pub type Archive {
  Archive(
    manifest: codec.Manifest,
    events: List(types.TraceEvent),
    graph: dag.CausalGraph,
    clocks: types.ClockCalibration,
  )
}

pub type EventWindow {
  EventWindow(
    events: List(types.TraceEvent),
    total: Int,
    start: Int,
    limit: Int,
    clocks: types.ClockCalibration,
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
  InvalidGraph(message: String)
  MigrationRequiresDistinctOutput
  CodecError(message: String)
  IoError(message: String)
}

/// Save only schema v2. Callers without clock probes receive an explicit empty
/// calibration; no wall-clock anchor is invented.
pub fn save(
  path: String,
  manifest: codec.Manifest,
  events: List(types.TraceEvent),
) -> Result(Nil, StorageError) {
  save_with_clocks(path, manifest, events, types.empty_calibration())
}

pub fn save_with_clocks(
  path: String,
  manifest: codec.Manifest,
  events: List(types.TraceEvent),
  clocks: types.ClockCalibration,
) -> Result(Nil, StorageError) {
  let manifest =
    codec.Manifest(..manifest, schema_version: codec.schema_version)
  let manifest_json = codec.encode_manifest(manifest)
  use validated_manifest <- try_result(
    codec.decode_manifest(manifest_json)
    |> map_error(fn(error) { CodecError(string.inspect(error)) }),
  )
  let event_lines = list.map(events, codec.encode_event)
  use validated_events <- try_result(decode_events(event_lines, []))
  use Nil <- try_result(validate_event_nodes(
    validated_manifest,
    validated_events,
  ))
  use graph <- try_result(
    dag.build(validated_events)
    |> map_error(fn(error) { InvalidGraph(string.inspect(error)) }),
  )
  let chunks = event_chunks(validated_events)
  let graph_segments = make_graph_segments(chunks, graph)
  let graph_lines = list.map(graph_segments, codec.encode_graph_segment)
  use validated_segments <- try_result(decode_graph_segments(graph_lines, []))
  use _validated_graph <- try_result(validate_v2_graph(
    validated_events,
    validated_segments,
  ))
  let clocks_json = codec.encode_clocks(clocks)
  use validated_clocks <- try_result(
    codec.decode_clocks(clocks_json)
    |> map_error(fn(error) { CodecError(string.inspect(error)) }),
  )
  use Nil <- try_result(validate_clock_nodes(
    validated_manifest,
    validated_clocks,
  ))
  write_container(path, manifest_json, event_lines, graph_lines, clocks_json)
  |> map_error(classify_error)
}

/// Read both generations. V1 values are normalized per node and marked as
/// legacy-unverified by the codec. They are never written back as v1.
pub fn load(path: String) -> Result(Archive, StorageError) {
  use payload <- try_result(read_container(path) |> map_error(classify_error))
  let #(manifest_json, event_lines, graph_lines, clocks_json) = payload
  use manifest <- try_result(
    codec.decode_manifest(manifest_json)
    |> map_error(fn(error) { CodecError(string.inspect(error)) }),
  )
  use decoded_events <- try_result(decode_events(event_lines, []))
  case manifest.schema_version {
    1 -> {
      let events = normalize_legacy_instants(decoded_events)
      use graph <- try_result(
        dag.build(events)
        |> map_error(fn(error) { InvalidGraph(string.inspect(error)) }),
      )
      Ok(Archive(manifest, events, graph, types.empty_calibration()))
    }
    2 -> {
      use Nil <- try_result(validate_event_nodes(manifest, decoded_events))
      use segments <- try_result(decode_graph_segments(graph_lines, []))
      use clocks <- try_result(
        codec.decode_clocks(clocks_json)
        |> map_error(fn(error) { CodecError(string.inspect(error)) }),
      )
      use graph <- try_result(validate_v2_graph(decoded_events, segments))
      use Nil <- try_result(validate_clock_nodes(manifest, clocks))
      Ok(Archive(manifest, decoded_events, graph, clocks))
    }
    version ->
      Error(CodecError("UnknownSchemaVersion(" <> int.to_string(version) <> ")"))
  }
}

/// Explicit, non-destructive migration. The source is never modified and the
/// destination must be a different path.
pub fn migrate(
  source: String,
  output: String,
  tool_version: String,
) -> Result(Nil, StorageError) {
  case source == output {
    True -> Error(MigrationRequiresDistinctOutput)
    False -> {
      use archive <- try_result(load(source))
      let manifest =
        codec.Manifest(
          ..archive.manifest,
          schema_version: codec.schema_version,
          tool_version: tool_version,
        )
      save_with_clocks(output, manifest, archive.events, archive.clocks)
    }
  }
}

/// Full validation includes structural decoding, graph/reference checks, and
/// complete checksum verification performed by `read_container`.
pub fn validate(path: String) -> Result(Archive, StorageError) {
  load(path)
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
    False -> {
      use archive <- try_result(load(path))
      Ok(EventWindow(
        events: archive.events |> list.drop(start) |> list.take(limit),
        total: list.length(archive.events),
        start: start,
        limit: limit,
        clocks: archive.clocks,
      ))
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
    False, False -> {
      use archive <- try_result(load(path))
      let folded = string.lowercase(normalized)
      let matches =
        list.filter(archive.events, fn(event) {
          event
          |> codec.encode_event
          |> string.lowercase
          |> string.contains(folded)
        })
      Ok(EventWindow(
        events: matches |> list.drop(start) |> list.take(limit),
        total: list.length(matches),
        start: start,
        limit: limit,
        clocks: archive.clocks,
      ))
    }
  }
}

fn event_chunks(
  events: List(types.TraceEvent),
) -> List(List(types.TraceEvent)) {
  case events {
    [] -> [[]]
    _ -> event_chunks_loop(events, [])
  }
}

fn event_chunks_loop(
  events: List(types.TraceEvent),
  accumulator: List(List(types.TraceEvent)),
) -> List(List(types.TraceEvent)) {
  case events {
    [] -> list.reverse(accumulator)
    _ -> {
      let chunk = list.take(events, segment_event_limit)
      event_chunks_loop(list.drop(events, segment_event_limit), [
        chunk,
        ..accumulator
      ])
    }
  }
}

fn make_graph_segments(
  chunks: List(List(types.TraceEvent)),
  graph: dag.CausalGraph,
) -> List(codec.GraphSegment) {
  let indexed_chunks =
    list.index_map(chunks, fn(chunk, index) { #(index, chunk) })
  let event_segments =
    list.fold(indexed_chunks, dict.new(), fn(index, indexed_chunk) {
      let #(segment, chunk) = indexed_chunk
      list.fold(chunk, index, fn(index, event) {
        dict.insert(index, event.id, segment)
      })
    })
  let edges_by_segment =
    list.fold(graph.edges, dict.new(), fn(index, edge) {
      let from_segment = dict.get(event_segments, edge.from)
      let to_segment = dict.get(event_segments, edge.to)
      case from_segment, to_segment {
        Ok(from), Ok(to) if from == to -> prepend_segment(index, from, edge)
        Ok(from), Ok(to) ->
          index
          |> prepend_segment(from, edge)
          |> prepend_segment(to, edge)
        _, _ -> index
      }
    })
  let boundaries_by_segment =
    list.fold(graph.boundaries, dict.new(), fn(index, boundary) {
      case dict.get(event_segments, boundary.event_id) {
        Ok(segment) -> prepend_segment(index, segment, boundary)
        Error(_) -> index
      }
    })
  list.map(indexed_chunks, fn(indexed_chunk) {
    let #(segment, chunk) = indexed_chunk
    codec.GraphSegment(
      event_ids: list.map(chunk, fn(event) { event.id }),
      edges: dict.get(edges_by_segment, segment)
        |> result.unwrap([])
        |> list.reverse,
      boundaries: dict.get(boundaries_by_segment, segment)
        |> result.unwrap([])
        |> list.reverse,
    )
  })
}

fn prepend_segment(
  index: Dict(Int, List(item)),
  segment: Int,
  item: item,
) -> Dict(Int, List(item)) {
  let existing = dict.get(index, segment) |> result.unwrap([])
  dict.insert(index, segment, [item, ..existing])
}

fn validate_v2_graph(
  events: List(types.TraceEvent),
  segments: List(codec.GraphSegment),
) -> Result(dag.CausalGraph, StorageError) {
  use graph <- try_result(
    dag.build(events)
    |> map_error(fn(error) { InvalidGraph(string.inspect(error)) }),
  )
  let expected = make_graph_segments(event_chunks(events), graph)
  case segments == expected {
    True -> Ok(graph)
    False ->
      Error(InvalidGraph(
        "graph segments do not match event boundaries or causal references",
      ))
  }
}

fn validate_clock_nodes(
  manifest: codec.Manifest,
  clocks: types.ClockCalibration,
) -> Result(Nil, StorageError) {
  case
    list.all(clocks.nodes, fn(clock) {
      list.contains(manifest.nodes, clock.node)
    })
  {
    True -> Ok(Nil)
    False -> Error(InvalidGraph("clock calibration references an unknown node"))
  }
}

fn validate_event_nodes(
  manifest: codec.Manifest,
  events: List(types.TraceEvent),
) -> Result(Nil, StorageError) {
  case
    list.all(events, fn(event) { list.contains(manifest.nodes, event.node) })
  {
    True -> Ok(Nil)
    False ->
      Error(CodecError(
        "InvalidField(\"events.node\", \"references a node not declared by the manifest\")",
      ))
  }
}

fn normalize_legacy_instants(
  events: List(types.TraceEvent),
) -> List(types.TraceEvent) {
  let origins =
    list.fold(events, dict.new(), fn(origins, event) {
      case dict.get(origins, event.node) {
        Error(_) ->
          dict.insert(origins, event.node, event.local_instant.offset_ns)
        Ok(origin) ->
          dict.insert(
            origins,
            event.node,
            int.min(origin, event.local_instant.offset_ns),
          )
      }
    })
  normalize_legacy_loop(events, origins, dict.new(), [])
}

fn normalize_legacy_loop(
  events: List(types.TraceEvent),
  origins: Dict(String, Int),
  orders: Dict(String, Int),
  accumulator: List(types.TraceEvent),
) -> List(types.TraceEvent) {
  case events {
    [] -> list.reverse(accumulator)
    [event, ..rest] -> {
      let origin = dict.get(origins, event.node) |> result.unwrap(0)
      let order = dict.get(orders, event.node) |> result.unwrap(0)
      let normalized =
        types.TraceEvent(
          ..event,
          local_instant: types.LocalInstant(
            event.local_instant.offset_ns - origin,
            order,
          ),
        )
      normalize_legacy_loop(
        rest,
        origins,
        dict.insert(orders, event.node, order + 1),
        [normalized, ..accumulator],
      )
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

fn decode_graph_segments(
  lines: List(String),
  accumulator: List(codec.GraphSegment),
) -> Result(List(codec.GraphSegment), StorageError) {
  case lines {
    [] -> Ok(list.reverse(accumulator))
    [line, ..rest] ->
      case codec.decode_graph_segment(line) {
        Ok(segment) -> decode_graph_segments(rest, [segment, ..accumulator])
        Error(error) -> Error(CodecError(string.inspect(error)))
      }
  }
}

fn classify_error(reason: String) -> StorageError {
  case reason {
    "invalid_container" -> InvalidContainer
    "zip_bomb" -> ZipBomb
    "checksum_mismatch" | "invalid_checksums" -> ChecksumMismatch
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
  graph_segments: List(String),
  clocks_json: String,
) -> Result(Nil, String)

@external(erlang, "beamtrace_storage_ffi", "read_container")
fn read_container(
  path: String,
) -> Result(#(String, List(String), List(String), String), String)

@external(erlang, "beamtrace_storage_ffi", "list_entries")
fn list_entries(path: String) -> Result(List(String), String)
