// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime
import beamtrace_runtime/mcp
import beamtrace_runtime/storage
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import v2_fixture

pub fn legacy_initialize_and_modern_discover_are_both_supported_test() {
  let #(legacy_waiting, legacy_response) =
    mcp.handle_with(
      mcp.new_connection(),
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{"
        <> "\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},"
        <> "\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}",
    )
  let assert Some(legacy) = legacy_response
  legacy
  |> string.contains("\"protocolVersion\":\"2025-11-25\"")
  |> should.be_true()
  legacy
  |> string.contains("\"tools\":{\"listChanged\":false}")
  |> should.be_true()
  legacy
  |> string.contains("\"version\":\"" <> beamtrace_runtime.version <> "\"")
  |> should.be_true()
  let #(legacy_ready, initialized_response) =
    mcp.handle_with(
      legacy_waiting,
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
    )
  initialized_response |> should.equal(None)
  let #(_, legacy_tools_response) =
    mcp.handle_with(
      legacy_ready,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
    )
  let assert Some(legacy_tools) = legacy_tools_response
  legacy_tools |> string.contains("\"tools\":[") |> should.be_true()

  let assert Some(modern) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":\"discover\",\"method\":\"server/discover\",\"params\":{"
      <> modern_meta()
      <> "}}",
    )
  modern
  |> string.contains("\"supportedVersions\":[\"2026-07-28\"]")
  |> should.be_true()
  modern |> string.contains("\"id\":\"discover\"") |> should.be_true()
  modern |> string.contains("\"resultType\":\"complete\"") |> should.be_true()
  modern
  |> string.contains("\"io.modelcontextprotocol/serverInfo\"")
  |> should.be_true()
}

pub fn tools_are_deterministic_and_explicitly_read_only_test() {
  let assert Some(response) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{"
      <> modern_meta()
      <> "}}",
    )
  response
  |> string.contains("\"name\":\"trace_search\"")
  |> should.be_true()
  response
  |> string.contains("\"name\":\"event_get\"")
  |> should.be_true()
  response
  |> string.contains("\"name\":\"compare_summary\"")
  |> should.be_true()
  response
  |> string.contains("\"name\":\"trace_overview\"")
  |> should.be_true()
  response |> string.contains("\"readOnlyHint\":true") |> should.be_true()
  response |> string.contains("\"destructiveHint\":false") |> should.be_true()
  response |> string.contains("\"outputSchema\":{") |> should.be_true()
  response
  |> string.contains("https://json-schema.org/draft/2020-12/schema")
  |> should.be_true()
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
      local_instant: v2_fixture.instant(10),
      kind: types.Stop("needle-mcp"),
      evidence: types.Exact,
    )
  let manifest = v2_fixture.manifest("capture-mcp", ["fixture@host"])
  storage.save(path, manifest, [event]) |> should.equal(Ok(Nil))

  let assert Some(response) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{"
      <> modern_meta()
      <> ",\"name\":\"trace_search\",\"arguments\":{"
      <> "\"path\":\""
      <> path
      <> "\",\"query\":\"needle-mcp\",\"start\":0,\"limit\":10}}}",
    )
  response |> string.contains("event-mcp") |> should.be_true()
  response |> string.contains("\"isError\":false") |> should.be_true()
  response
  |> string.contains("\"matches\":[{\"match_index\":0,\"event\":{")
  |> should.be_true()
  response
  |> string.contains("\"structuredContent\":{\"start\":0")
  |> should.be_true()
}

pub fn notifications_have_no_stdout_response_and_unknown_tools_fail_closed_test() {
  mcp.handle("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
  |> should.equal(None)

  let assert Some(response) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{"
      <> modern_meta()
      <> ",\"name\":\"process_kill\",\"arguments\":{}}}",
    )
  response |> string.contains("\"code\":-32602") |> should.be_true()
  response |> string.contains("process_kill") |> should.be_false()
}

pub fn json_rpc_syntax_request_shape_method_and_tool_errors_are_distinct_test() {
  let assert Some(parse_error) = mcp.handle("{")
  parse_error |> string.contains("\"code\":-32700") |> should.be_true()

  let assert Some(invalid_request) =
    mcp.handle("{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"tools/list\"}")
  invalid_request
  |> string.contains("\"code\":-32600")
  |> should.be_true()

  let assert Some(null_id) =
    mcp.handle("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"tools/list\"}")
  null_id |> string.contains("\"code\":-32600") |> should.be_true()

  let assert Some(method_error) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"traces/delete\",\"params\":{"
      <> modern_meta()
      <> "}}",
    )
  method_error |> string.contains("\"code\":-32601") |> should.be_true()

  let assert Some(tool_error) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{"
      <> modern_meta()
      <> ",\"name\":\"event_get\",\"arguments\":{"
      <> "\"path\":\"build/missing-official.beamtrace\",\"index\":0}}}",
    )
  tool_error |> string.contains("\"isError\":true") |> should.be_true()
  tool_error |> string.contains("\"error\":") |> should.be_false()
}

pub fn modern_notifications_are_silent_and_preserve_connection_state_test() {
  let #(modern, discover_response) =
    mcp.handle_with(
      mcp.new_connection(),
      "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"server/discover\",\"params\":{"
        <> modern_meta()
        <> "}}",
    )
  let assert Some(_) = discover_response

  let #(still_modern, notification_response) =
    mcp.handle_with(
      modern,
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{"
        <> modern_meta()
        <> ",\"requestId\":\"not-active\"}}",
    )
  notification_response |> should.equal(None)

  let #(_, listed_response) =
    mcp.handle_with(
      still_modern,
      "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/list\",\"params\":{"
        <> modern_meta()
        <> "}}",
    )
  let assert Some(listed) = listed_response
  listed |> string.contains("\"tools\":[") |> should.be_true()
}

pub fn modern_metadata_and_version_errors_follow_the_2026_contract_test() {
  let assert Some(missing) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\",\"params\":{}}",
    )
  missing |> string.contains("\"code\":-32602") |> should.be_true()

  let assert Some(unsupported) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\",\"params\":{"
      <> "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2099-01-01\","
      <> "\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
    )
  unsupported |> string.contains("\"code\":-32022") |> should.be_true()
  unsupported
  |> string.contains("\"supported\":[\"2026-07-28\"]")
  |> should.be_true()
  unsupported
  |> string.contains("\"requested\":\"2099-01-01\"")
  |> should.be_true()
}

pub fn event_get_and_trace_overview_return_bounded_json_objects_test() {
  let path = "build/beamtrace-mcp-overview-test.beamtrace"
  let process =
    types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", "<0.2.0>"),
      logical: None,
      evidence: [],
    )
  let events = [
    types.TraceEvent(
      "event-overview-1",
      "root-overview",
      "fixture@host",
      process,
      v2_fixture.instant(20),
      types.Stop("done"),
      types.Exact,
    ),
    types.TraceEvent(
      "event-overview-2",
      "root-overview",
      "fixture@host",
      process,
      v2_fixture.instant(10),
      types.Metric("queue", 2.0),
      types.Exact,
    ),
  ]
  let manifest = v2_fixture.manifest("capture-overview", ["fixture@host"])
  storage.save(path, manifest, events) |> should.equal(Ok(Nil))

  let assert Some(event_response) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{"
      <> modern_meta()
      <> ",\"name\":\"event_get\",\"arguments\":{\"path\":\""
      <> path
      <> "\",\"index\":0}}}",
    )
  event_response
  |> string.contains("\"event\":{\"schema_version\":2")
  |> should.be_true()
  event_response
  |> string.contains("\"event\":\"{")
  |> should.be_false()

  let assert Some(overview) =
    mcp.handle(
      "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{"
      <> modern_meta()
      <> ",\"name\":\"trace_overview\",\"arguments\":{\"path\":\""
      <> path
      <> "\"}}}",
    )
  overview |> string.contains("\"event_count\":2") |> should.be_true()
  overview
  |> string.contains(
    "\"node_local_time_ranges\":[{\"node\":\"fixture@host\",\"start_offset_ns\":10,\"end_offset_ns\":20}]",
  )
  |> should.be_true()
  overview
  |> string.contains("\"event_kinds\":{\"metric\":1,\"stop\":1}")
  |> should.be_true()
}

fn modern_meta() -> String {
  "\"_meta\":{"
  <> "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\","
  <> "\"io.modelcontextprotocol/clientCapabilities\":{},"
  <> "\"io.modelcontextprotocol/clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}"
}
