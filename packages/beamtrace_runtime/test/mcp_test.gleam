// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/types
import beamtrace_runtime
import beamtrace_runtime/mcp
import beamtrace_runtime/storage
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn legacy_initialize_and_modern_discover_are_both_supported_test() {
  let assert Some(legacy) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{"
      <> "\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},"
      <> "\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}",
    )
  legacy
  |> string.contains("\"protocolVersion\":\"2025-11-25\"")
  |> should.be_true()
  legacy |> string.contains("\"tools\":{}") |> should.be_true()
  legacy
  |> string.contains("\"version\":\"" <> beamtrace_runtime.version <> "\"")
  |> should.be_true()

  let assert Some(modern) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":\"discover\",\"method\":\"server/discover\",\"params\":{}}",
    )
  modern
  |> string.contains("\"supportedVersions\":[\"2026-07-28\"]")
  |> should.be_true()
  modern |> string.contains("\"id\":\"discover\"") |> should.be_true()
}

pub fn tools_are_deterministic_and_explicitly_read_only_test() {
  let assert Some(response) =
    mcp.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
  response
  |> string.contains("\"name\":\"trace_search\"")
  |> should.be_true()
  response
  |> string.contains("\"name\":\"event_get\"")
  |> should.be_true()
  response
  |> string.contains("\"name\":\"compare_summary\"")
  |> should.be_true()
  response |> string.contains("\"readOnlyHint\":true") |> should.be_true()
  response |> string.contains("\"destructiveHint\":false") |> should.be_true()
}

pub fn trace_search_tool_reads_a_bounded_archive_window_test() {
  let path = "build/beamtrace-mcp-search-test.beamtrace"
  let process =
    types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", "<0.1.0>"),
      logical: None,
      evidence: [],
    )
  let event =
    types.TraceEvent(
      id: "event-mcp",
      root_id: "root-mcp",
      node: "fixture@host",
      process: process,
      local_timestamp_ns: 10,
      kind: types.Stop("needle-mcp"),
      evidence: types.Exact,
    )
  let manifest =
    codec.Manifest(
      schema_version: 1,
      tool_version: "0.1.0",
      capture_id: "capture-mcp",
      nodes: ["fixture@host"],
      completeness: types.Complete,
      privacy: types.Metadata,
      checksums: [],
    )
  storage.save(path, manifest, [event]) |> should.equal(Ok(Nil))

  let assert Some(response) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{"
      <> "\"name\":\"trace_search\",\"arguments\":{"
      <> "\"path\":\""
      <> path
      <> "\",\"query\":\"needle-mcp\",\"start\":0,\"limit\":10}}}",
    )
  response |> string.contains("event-mcp") |> should.be_true()
  response |> string.contains("\"isError\":false") |> should.be_true()
}

pub fn notifications_have_no_stdout_response_and_unknown_tools_fail_closed_test() {
  mcp.handle("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
  |> should.equal(None)

  let assert Some(response) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"process_kill\",\"arguments\":{}}}",
    )
  response |> string.contains("\"code\":-32602") |> should.be_true()
  response |> string.contains("process_kill") |> should.be_false()
}
