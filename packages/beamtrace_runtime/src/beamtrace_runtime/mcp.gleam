// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/diff
import beamtrace_runtime/internal/version as runtime_version
import beamtrace_runtime/storage
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const legacy_protocol_version = "2025-11-25"

const modern_protocol_version = "2026-07-28"

const max_message_bytes = 1_048_576

type RpcId {
  IntegerId(Int)
  TextId(String)
}

type Envelope {
  Envelope(jsonrpc: String, id: Option(RpcId), method: String)
}

type SearchArguments {
  SearchArguments(path: String, query: String, start: Int, limit: Int)
}

type EventArguments {
  EventArguments(path: String, index: Int)
}

type CompareArguments {
  CompareArguments(left_path: String, right_path: String)
}

pub type Input {
  EndOfInput
  Line(String)
  InputError(String)
}

pub fn run() -> Nil {
  case read_line() {
    EndOfInput -> Nil
    InputError(reason) -> {
      write_error("beamtrace mcp: " <> reason)
      Nil
    }
    Line(source) -> {
      case handle(source) {
        None -> Nil
        Some(response) -> write_line(response)
      }
      run()
    }
  }
}

pub fn handle(source: String) -> Option(String) {
  case string.byte_size(source) > max_message_bytes {
    True -> Some(error_response(None, -32_700, "Parse error"))
    False ->
      case json.parse(source, envelope_decoder()) {
        Error(_) -> Some(error_response(None, -32_700, "Parse error"))
        Ok(Envelope(_, None, _)) -> None
        Ok(Envelope(jsonrpc, Some(id), method)) ->
          case jsonrpc == "2.0" {
            False -> Some(error_response(Some(id), -32_600, "Invalid Request"))
            True -> Some(dispatch(id, method, source))
          }
      }
  }
}

fn dispatch(id: RpcId, method: String, source: String) -> String {
  case method {
    "initialize" -> initialize_response(id, source)
    "server/discover" -> success_response(id, discover_result())
    "ping" -> success_response(id, json.object([]))
    "tools/list" -> success_response(id, tools_result())
    "tools/call" -> call_tool(id, source)
    _ -> error_response(Some(id), -32_601, "Method not found")
  }
}

fn initialize_response(id: RpcId, source: String) -> String {
  case json.parse(source, initialize_decoder()) {
    Error(_) -> error_response(Some(id), -32_602, "Invalid params")
    Ok(requested) -> {
      let negotiated = case
        list.contains(
          ["2024-11-05", "2025-03-26", "2025-06-18", legacy_protocol_version],
          requested,
        )
      {
        True -> requested
        False -> legacy_protocol_version
      }
      success_response(
        id,
        json.object([
          #("protocolVersion", json.string(negotiated)),
          #("capabilities", capabilities()),
          #("serverInfo", server_info()),
          #(
            "instructions",
            json.string(
              "Read-only access to bounded, metadata-shaped BeamTrace traces.",
            ),
          ),
        ]),
      )
    }
  }
}

fn discover_result() -> json.Json {
  json.object([
    #("resultType", json.string("complete")),
    #("supportedVersions", json.array([modern_protocol_version], json.string)),
    #("capabilities", capabilities()),
    #("ttlMs", json.int(3_600_000)),
    #("cacheScope", json.string("public")),
    #(
      "instructions",
      json.string("Read-only access to bounded, metadata-shaped traces."),
    ),
    #(
      "_meta",
      json.object([#("io.modelcontextprotocol/serverInfo", server_info())]),
    ),
  ])
}

fn capabilities() -> json.Json {
  json.object([#("tools", json.object([]))])
}

fn server_info() -> json.Json {
  json.object([
    #("name", json.string("beamtrace")),
    #("version", json.string(runtime_version.current)),
  ])
}

fn tools_result() -> json.Json {
  json.object([
    #("resultType", json.string("complete")),
    #("tools", json.array(tool_catalog(), fn(tool) { tool })),
    #("ttlMs", json.int(3_600_000)),
    #("cacheScope", json.string("public")),
  ])
}

fn tool_catalog() -> List(json.Json) {
  [
    tool(
      "compare_summary",
      "Compare two .beamtrace files by logical actor and causal event shape.",
      [
        #("left_path", string_schema("Left .beamtrace path")),
        #("right_path", string_schema("Right .beamtrace path")),
      ],
      ["left_path", "right_path"],
    ),
    tool(
      "event_get",
      "Read one event by zero-based index without loading the full trace.",
      [
        #("path", string_schema(".beamtrace path")),
        #("index", integer_schema("Zero-based event index", 0, 1_000_000_000)),
      ],
      ["path", "index"],
    ),
    tool(
      "trace_search",
      "Search canonical metadata across an archive with a bounded result window.",
      [
        #("path", string_schema(".beamtrace path")),
        #("query", string_schema("Case-insensitive text, at most 256 bytes")),
        #(
          "start",
          integer_schema("Zero-based matching-event offset", 0, 1_000_000_000),
        ),
        #("limit", integer_schema("Maximum returned events", 1, 200)),
      ],
      ["path", "query"],
    ),
  ]
}

fn tool(
  name: String,
  description: String,
  properties: List(#(String, json.Json)),
  required: List(String),
) -> json.Json {
  json.object([
    #("name", json.string(name)),
    #("description", json.string(description)),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #("properties", json.object(properties)),
        #("required", json.array(required, json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    ),
    #(
      "annotations",
      json.object([
        #("readOnlyHint", json.bool(True)),
        #("destructiveHint", json.bool(False)),
        #("idempotentHint", json.bool(True)),
        #("openWorldHint", json.bool(False)),
      ]),
    ),
  ])
}

fn string_schema(description: String) -> json.Json {
  json.object([
    #("type", json.string("string")),
    #("description", json.string(description)),
  ])
}

fn integer_schema(
  description: String,
  minimum: Int,
  maximum: Int,
) -> json.Json {
  json.object([
    #("type", json.string("integer")),
    #("description", json.string(description)),
    #("minimum", json.int(minimum)),
    #("maximum", json.int(maximum)),
  ])
}

fn call_tool(id: RpcId, source: String) -> String {
  case json.parse(source, tool_name_decoder()) {
    Error(_) -> error_response(Some(id), -32_602, "Invalid params")
    Ok("trace_search") -> call_trace_search(id, source)
    Ok("event_get") -> call_event_get(id, source)
    Ok("compare_summary") -> call_compare_summary(id, source)
    Ok(_) -> error_response(Some(id), -32_602, "Unknown tool")
  }
}

fn call_trace_search(id: RpcId, source: String) -> String {
  case json.parse(source, search_arguments_decoder()) {
    Error(_) -> error_response(Some(id), -32_602, "Invalid params")
    Ok(arguments) ->
      case
        valid_trace_path(arguments.path),
        arguments.start >= 0,
        arguments.limit >= 1 && arguments.limit <= 200
      {
        False, _, _ | _, False, _ | _, _, False ->
          error_response(Some(id), -32_602, "Invalid params")
        True, True, True ->
          case
            storage.search(
              arguments.path,
              arguments.query,
              start: arguments.start,
              limit: arguments.limit,
            )
          {
            Error(_) -> tool_error(id, "Trace search failed")
            Ok(window) ->
              tool_success(
                id,
                json.object([
                  #("start", json.int(window.start)),
                  #("limit", json.int(window.limit)),
                  #("total", json.int(window.total)),
                  #(
                    "events",
                    json.array(window.events, fn(event) {
                      json.string(codec.encode_event(event))
                    }),
                  ),
                ]),
              )
          }
      }
  }
}

fn call_event_get(id: RpcId, source: String) -> String {
  case json.parse(source, event_arguments_decoder()) {
    Error(_) -> error_response(Some(id), -32_602, "Invalid params")
    Ok(arguments) ->
      case valid_trace_path(arguments.path) && arguments.index >= 0 {
        False -> error_response(Some(id), -32_602, "Invalid params")
        True ->
          case
            storage.window(arguments.path, start: arguments.index, limit: 1)
          {
            Ok(storage.EventWindow([event], total, _, _)) ->
              tool_success(
                id,
                json.object([
                  #("index", json.int(arguments.index)),
                  #("total", json.int(total)),
                  #("event", json.string(codec.encode_event(event))),
                ]),
              )
            Ok(_) -> tool_error(id, "Event not found")
            Error(_) -> tool_error(id, "Event read failed")
          }
      }
  }
}

fn call_compare_summary(id: RpcId, source: String) -> String {
  case json.parse(source, compare_arguments_decoder()) {
    Error(_) -> error_response(Some(id), -32_602, "Invalid params")
    Ok(arguments) ->
      case
        valid_trace_path(arguments.left_path),
        valid_trace_path(arguments.right_path)
      {
        True, True ->
          case
            storage.load(arguments.left_path),
            storage.load(arguments.right_path)
          {
            Ok(left), Ok(right) -> {
              let report = diff.compare(left.events, right.events)
              tool_success(
                id,
                json.object([
                  #("added", json.int(report.added)),
                  #("removed", json.int(report.removed)),
                  #("changed", json.int(report.changed)),
                ]),
              )
            }
            _, _ -> tool_error(id, "Trace comparison failed")
          }
        _, _ -> error_response(Some(id), -32_602, "Invalid params")
      }
  }
}

fn tool_success(id: RpcId, payload: json.Json) -> String {
  let text = json.to_string(payload)
  success_response(
    id,
    json.object([
      #("resultType", json.string("complete")),
      #(
        "content",
        json.array(
          [
            json.object([
              #("type", json.string("text")),
              #("text", json.string(text)),
            ]),
          ],
          fn(content) { content },
        ),
      ),
      #("structuredContent", payload),
      #("isError", json.bool(False)),
    ]),
  )
}

fn tool_error(id: RpcId, message: String) -> String {
  success_response(
    id,
    json.object([
      #("resultType", json.string("complete")),
      #(
        "content",
        json.array(
          [
            json.object([
              #("type", json.string("text")),
              #("text", json.string(message)),
            ]),
          ],
          fn(content) { content },
        ),
      ),
      #("isError", json.bool(True)),
    ]),
  )
}

fn success_response(id: RpcId, result: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_json(id)),
    #("result", result),
  ])
  |> json.to_string
}

fn error_response(id: Option(RpcId), code: Int, message: String) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", case id {
      Some(value) -> id_json(value)
      None -> json.null()
    }),
    #(
      "error",
      json.object([
        #("code", json.int(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
  |> json.to_string
}

fn id_json(id: RpcId) -> json.Json {
  case id {
    IntegerId(value) -> json.int(value)
    TextId(value) -> json.string(value)
  }
}

fn valid_trace_path(path: String) -> Bool {
  let size = string.byte_size(path)
  size > 0
  && size <= 4096
  && string.ends_with(string.lowercase(path), ".beamtrace")
  && !string.contains(path, "\u{0}")
  && !string.contains(path, "\n")
  && !string.contains(path, "\r")
}

fn envelope_decoder() -> decode.Decoder(Envelope) {
  use jsonrpc <- decode.field("jsonrpc", decode.string)
  use id <- decode.optional_field("id", None, decode.optional(id_decoder()))
  use method <- decode.field("method", decode.string)
  decode.success(Envelope(jsonrpc, id, method))
}

fn id_decoder() -> decode.Decoder(RpcId) {
  decode.one_of(decode.int |> decode.map(IntegerId), or: [
    decode.string |> decode.map(TextId),
  ])
}

fn initialize_decoder() -> decode.Decoder(String) {
  decode.at(["params", "protocolVersion"], decode.string)
}

fn tool_name_decoder() -> decode.Decoder(String) {
  decode.at(["params", "name"], decode.string)
}

fn search_arguments_decoder() -> decode.Decoder(SearchArguments) {
  decode.at(["params", "arguments"], search_arguments_object_decoder())
}

fn search_arguments_object_decoder() -> decode.Decoder(SearchArguments) {
  use path <- decode.field("path", decode.string)
  use query <- decode.field("query", decode.string)
  use start <- decode.optional_field("start", 0, decode.int)
  use limit <- decode.optional_field("limit", 50, decode.int)
  decode.success(SearchArguments(path, query, start, limit))
}

fn event_arguments_decoder() -> decode.Decoder(EventArguments) {
  decode.at(["params", "arguments"], event_arguments_object_decoder())
}

fn event_arguments_object_decoder() -> decode.Decoder(EventArguments) {
  use path <- decode.field("path", decode.string)
  use index <- decode.field("index", decode.int)
  decode.success(EventArguments(path, index))
}

fn compare_arguments_decoder() -> decode.Decoder(CompareArguments) {
  decode.at(["params", "arguments"], compare_arguments_object_decoder())
}

fn compare_arguments_object_decoder() -> decode.Decoder(CompareArguments) {
  use left_path <- decode.field("left_path", decode.string)
  use right_path <- decode.field("right_path", decode.string)
  decode.success(CompareArguments(left_path, right_path))
}

@external(erlang, "beamtrace_mcp_stdio_ffi", "read_line")
fn read_line() -> Input

@external(erlang, "beamtrace_mcp_stdio_ffi", "write_line")
fn write_line(value: String) -> Nil

@external(erlang, "beamtrace_mcp_stdio_ffi", "write_error")
fn write_error(value: String) -> Nil
