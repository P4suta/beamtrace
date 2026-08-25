// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/diff
import beamtrace/types
import beamtrace_runtime/internal/version as runtime_version
import beamtrace_runtime/storage
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
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

type OverviewArguments {
  OverviewArguments(path: String)
}

type Era {
  AwaitingNegotiation
  LegacyAwaitingInitialized(protocol_version: String)
  LegacyReady(protocol_version: String)
  Modern
}

pub opaque type Connection {
  Connection(era: Era)
}

pub type Input {
  EndOfInput
  Line(String)
  InputError(String)
}

pub fn run() -> Nil {
  run_connection(new_connection())
}

fn run_connection(connection: Connection) -> Nil {
  case read_line() {
    EndOfInput -> Nil
    InputError(reason) -> {
      write_error("beamtrace mcp: " <> reason)
      Nil
    }
    Line(source) -> {
      let #(next, response) = handle_with(connection, source)
      case response {
        None -> Nil
        Some(response) -> write_line(response)
      }
      run_connection(next)
    }
  }
}

pub fn new_connection() -> Connection {
  Connection(AwaitingNegotiation)
}

pub fn handle(source: String) -> Option(String) {
  handle_with(new_connection(), source).1
}

pub fn handle_with(
  connection: Connection,
  source: String,
) -> #(Connection, Option(String)) {
  case string.byte_size(source) > max_message_bytes {
    True -> #(connection, Some(error_response(None, -32_700, "Parse error")))
    False ->
      case json.parse(source, decode.dynamic) {
        Error(_) -> #(
          connection,
          Some(error_response(None, -32_700, "Parse error")),
        )
        Ok(value) ->
          case decode.run(value, envelope_decoder()) {
            Error(_) -> #(
              connection,
              Some(error_response(None, -32_600, "Invalid Request")),
            )
            Ok(Envelope(jsonrpc, None, method)) ->
              case jsonrpc == "2.0" {
                False -> #(
                  connection,
                  Some(error_response(None, -32_600, "Invalid Request")),
                )
                True -> #(handle_notification(connection, method), None)
              }
            Ok(Envelope(jsonrpc, Some(id), method)) ->
              case jsonrpc == "2.0" {
                False -> #(
                  connection,
                  Some(error_response(Some(id), -32_600, "Invalid Request")),
                )
                True -> dispatch(connection, id, method, source)
              }
          }
      }
  }
}

fn handle_notification(connection: Connection, method: String) -> Connection {
  case connection, method {
    Connection(LegacyAwaitingInitialized(version)), "notifications/initialized"
    -> Connection(LegacyReady(version))
    _, _ -> connection
  }
}

fn dispatch(
  connection: Connection,
  id: RpcId,
  method: String,
  source: String,
) -> #(Connection, Option(String)) {
  let Connection(era) = connection
  case era, method {
    AwaitingNegotiation, "initialize" -> initialize_response(id, source)
    AwaitingNegotiation, _ -> dispatch_modern(connection, id, method, source)
    LegacyAwaitingInitialized(_), _ -> #(
      connection,
      Some(error_response(Some(id), -32_600, "Invalid Request")),
    )
    LegacyReady(_), "ping" -> #(
      connection,
      Some(success_response(id, json.object([]))),
    )
    LegacyReady(_), "tools/list" -> #(
      connection,
      Some(success_response(id, tools_result(False))),
    )
    LegacyReady(_), "tools/call" -> #(
      connection,
      Some(call_tool(id, source, False)),
    )
    LegacyReady(_), _ -> #(
      connection,
      Some(error_response(Some(id), -32_601, "Method not found")),
    )
    Modern, "initialize" | Modern, "ping" -> #(
      connection,
      Some(error_response(Some(id), -32_601, "Method not found")),
    )
    Modern, _ -> dispatch_modern(connection, id, method, source)
  }
}

fn dispatch_modern(
  connection: Connection,
  id: RpcId,
  method: String,
  source: String,
) -> #(Connection, Option(String)) {
  case json.parse(source, modern_metadata_decoder()) {
    Error(_) -> #(
      connection,
      Some(error_response(Some(id), -32_602, "Invalid params")),
    )
    Ok(requested) if requested != modern_protocol_version -> #(
      connection,
      Some(unsupported_version_response(id, requested)),
    )
    Ok(_) -> {
      let modern = Connection(Modern)
      let response = case method {
        "server/discover" -> success_response(id, discover_result())
        "tools/list" -> success_response(id, tools_result(True))
        "tools/call" -> call_tool(id, source, True)
        _ -> error_response(Some(id), -32_601, "Method not found")
      }
      #(modern, Some(response))
    }
  }
}

fn initialize_response(
  id: RpcId,
  source: String,
) -> #(Connection, Option(String)) {
  case json.parse(source, initialize_decoder()) {
    Error(_) -> #(
      new_connection(),
      Some(error_response(Some(id), -32_602, "Invalid params")),
    )
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
      #(
        Connection(LegacyAwaitingInitialized(negotiated)),
        Some(success_response(
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
        )),
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
  json.object([
    #("tools", json.object([#("listChanged", json.bool(False))])),
  ])
}

fn server_info() -> json.Json {
  json.object([
    #("name", json.string("beamtrace")),
    #("version", json.string(runtime_version.current)),
  ])
}

fn tools_result(modern: Bool) -> json.Json {
  let fields = [
    #("tools", json.array(tool_catalog(), fn(tool) { tool })),
    #("ttlMs", json.int(3_600_000)),
    #("cacheScope", json.string("public")),
  ]
  case modern {
    False -> json.object(fields)
    True -> json.object(list.append(modern_result_fields(), fields))
  }
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
      comparison_output_schema(),
    ),
    tool(
      "event_get",
      "Read one event by zero-based index without loading the full trace.",
      [
        #("path", string_schema(".beamtrace path")),
        #("index", integer_schema("Zero-based event index", 0, 1_000_000_000)),
      ],
      ["path", "index"],
      event_output_schema(),
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
      search_output_schema(),
    ),
    tool(
      "trace_overview",
      "Summarize version, cardinality, nodes, privacy, completeness, time range, and event kinds without returning trace payloads.",
      [#("path", string_schema(".beamtrace path"))],
      ["path"],
      overview_output_schema(),
    ),
  ]
}

fn tool(
  name: String,
  description: String,
  properties: List(#(String, json.Json)),
  required: List(String),
  output_schema: json.Json,
) -> json.Json {
  json.object([
    #("name", json.string(name)),
    #("description", json.string(description)),
    #(
      "inputSchema",
      json.object([
        #(
          "$schema",
          json.string("https://json-schema.org/draft/2020-12/schema"),
        ),
        #("type", json.string("object")),
        #("properties", json.object(properties)),
        #("required", json.array(required, json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    ),
    #("outputSchema", output_schema),
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

fn object_output_schema(
  properties: List(#(String, json.Json)),
  required: List(String),
) -> json.Json {
  json.object([
    #("$schema", json.string("https://json-schema.org/draft/2020-12/schema")),
    #("type", json.string("object")),
    #("properties", json.object(properties)),
    #("required", json.array(required, json.string)),
    #("additionalProperties", json.bool(False)),
  ])
}

fn comparison_output_schema() -> json.Json {
  let count = integer_schema("Event-shape count", 0, 1_000_000_000)
  object_output_schema(
    [#("added", count), #("removed", count), #("changed", count)],
    ["added", "removed", "changed"],
  )
}

fn event_object_schema() -> json.Json {
  json.object([#("type", json.string("object"))])
}

fn event_output_schema() -> json.Json {
  object_output_schema(
    [
      #("index", integer_schema("Event index", 0, 1_000_000_000)),
      #("total", integer_schema("Trace event count", 0, 1_000_000_000)),
      #("event", event_object_schema()),
    ],
    ["index", "total", "event"],
  )
}

fn search_output_schema() -> json.Json {
  let match_schema =
    object_output_schema(
      [
        #(
          "match_index",
          integer_schema(
            "Index within the matching result set",
            0,
            1_000_000_000,
          ),
        ),
        #("event", event_object_schema()),
      ],
      ["match_index", "event"],
    )
  object_output_schema(
    [
      #("start", integer_schema("Result offset", 0, 1_000_000_000)),
      #("limit", integer_schema("Requested limit", 1, 200)),
      #("total", integer_schema("Matching event count", 0, 1_000_000_000)),
      #(
        "matches",
        json.object([
          #("type", json.string("array")),
          #("maxItems", json.int(200)),
          #("items", match_schema),
        ]),
      ),
    ],
    ["start", "limit", "total", "matches"],
  )
}

fn overview_output_schema() -> json.Json {
  object_output_schema(
    [
      #("version", integer_schema("Archive schema version", 0, 1_000_000)),
      #("event_count", integer_schema("Trace event count", 0, 1_000_000_000)),
      #(
        "nodes",
        json.object([
          #("type", json.string("array")),
          #("maxItems", json.int(64)),
          #("items", json.object([#("type", json.string("string"))])),
        ]),
      ),
      #("privacy", string_schema("Trace privacy classification")),
      #("completeness", string_schema("Trace completeness")),
      #(
        "time_range",
        json.object([
          #("type", json.array(["object", "null"], json.string)),
        ]),
      ),
      #(
        "event_kinds",
        json.object([
          #("type", json.string("object")),
          #(
            "additionalProperties",
            integer_schema("Events of this kind", 0, 1_000_000_000),
          ),
          #("maxProperties", json.int(11)),
        ]),
      ),
    ],
    [
      "version",
      "event_count",
      "nodes",
      "privacy",
      "completeness",
      "time_range",
      "event_kinds",
    ],
  )
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

fn call_tool(id: RpcId, source: String, modern: Bool) -> String {
  case json.parse(source, tool_name_decoder()) {
    Error(_) -> error_response(Some(id), -32_602, "Invalid params")
    Ok("trace_search") -> call_trace_search(id, source, modern)
    Ok("event_get") -> call_event_get(id, source, modern)
    Ok("compare_summary") -> call_compare_summary(id, source, modern)
    Ok("trace_overview") -> call_trace_overview(id, source, modern)
    Ok(_) -> error_response(Some(id), -32_602, "Unknown tool")
  }
}

fn call_trace_search(id: RpcId, source: String, modern: Bool) -> String {
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
            Error(_) -> tool_error(id, "Trace search failed", modern)
            Ok(window) ->
              tool_success(
                id,
                json.object([
                  #("start", json.int(window.start)),
                  #("limit", json.int(window.limit)),
                  #("total", json.int(window.total)),
                  #(
                    "matches",
                    json.array(
                      list.index_map(window.events, fn(event, index) {
                        json.object([
                          #("match_index", json.int(window.start + index)),
                          #("event", codec.event_json(event)),
                        ])
                      }),
                      fn(match) { match },
                    ),
                  ),
                ]),
                modern,
              )
          }
      }
  }
}

fn call_event_get(id: RpcId, source: String, modern: Bool) -> String {
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
                  #("event", codec.event_json(event)),
                ]),
                modern,
              )
            Ok(_) -> tool_error(id, "Event not found", modern)
            Error(_) -> tool_error(id, "Event read failed", modern)
          }
      }
  }
}

fn call_compare_summary(id: RpcId, source: String, modern: Bool) -> String {
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
                modern,
              )
            }
            _, _ -> tool_error(id, "Trace comparison failed", modern)
          }
        _, _ -> error_response(Some(id), -32_602, "Invalid params")
      }
  }
}

fn call_trace_overview(id: RpcId, source: String, modern: Bool) -> String {
  case json.parse(source, overview_arguments_decoder()) {
    Error(_) -> error_response(Some(id), -32_602, "Invalid params")
    Ok(arguments) ->
      case valid_trace_path(arguments.path) {
        False -> error_response(Some(id), -32_602, "Invalid params")
        True ->
          case storage.load(arguments.path) {
            Error(_) -> tool_error(id, "Trace overview failed", modern)
            Ok(archive) -> tool_success(id, overview_json(archive), modern)
          }
      }
  }
}

fn tool_success(id: RpcId, payload: json.Json, modern: Bool) -> String {
  let text = json.to_string(payload)
  let fields = [
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
  ]
  success_response(id, case modern {
    False -> json.object(fields)
    True -> json.object(list.append(modern_result_fields(), fields))
  })
}

fn tool_error(id: RpcId, message: String, modern: Bool) -> String {
  let fields = [
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
  ]
  success_response(id, case modern {
    False -> json.object(fields)
    True -> json.object(list.append(modern_result_fields(), fields))
  })
}

fn modern_result_fields() -> List(#(String, json.Json)) {
  [
    #("resultType", json.string("complete")),
    #(
      "_meta",
      json.object([#("io.modelcontextprotocol/serverInfo", server_info())]),
    ),
  ]
}

fn overview_json(archive: storage.Archive) -> json.Json {
  let storage.Archive(manifest, events) = archive
  let kind_counts =
    event_kind_counts(events)
    |> dict.to_list
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  json.object([
    #("version", json.int(manifest.schema_version)),
    #("event_count", json.int(list.length(events))),
    #("nodes", json.array(list.take(manifest.nodes, 64), json.string)),
    #("privacy", json.string(privacy_name(manifest.privacy))),
    #("completeness", json.string(completeness_name(manifest.completeness))),
    #("time_range", event_time_range(events)),
    #(
      "event_kinds",
      json.object(
        list.map(kind_counts, fn(entry) { #(entry.0, json.int(entry.1)) }),
      ),
    ),
  ])
}

fn event_kind_counts(events: List(types.TraceEvent)) -> Dict(String, Int) {
  list.fold(events, dict.new(), fn(counts, event) {
    let name = event_kind_name(event.kind)
    let count = case dict.get(counts, name) {
      Ok(value) -> value
      Error(_) -> 0
    }
    dict.insert(counts, name, count + 1)
  })
}

fn event_time_range(events: List(types.TraceEvent)) -> json.Json {
  case events {
    [] -> json.null()
    [first, ..rest] -> {
      let range =
        list.fold(
          rest,
          #(first.local_timestamp_ns, first.local_timestamp_ns),
          fn(range, event) {
            #(
              int.min(range.0, event.local_timestamp_ns),
              int.max(range.1, event.local_timestamp_ns),
            )
          },
        )
      json.object([
        #("start_ns", json.int(range.0)),
        #("end_ns", json.int(range.1)),
      ])
    }
  }
}

fn privacy_name(privacy: types.Privacy) -> String {
  case privacy {
    types.Metadata -> "metadata"
    types.Raw(_) -> "raw"
  }
}

fn completeness_name(completeness: types.Completeness) -> String {
  case completeness {
    types.Complete -> "complete"
    types.Truncated(_) -> "truncated"
    types.Gapped(_) -> "gapped"
    types.PartialNode(_) -> "partial_node"
    types.InferredCapture(_) -> "inferred"
  }
}

fn event_kind_name(kind: types.TraceEventKind) -> String {
  case kind {
    types.Root(_, _) -> "root"
    types.Send(_, _, _) -> "send"
    types.Received(_, _, _) -> "received"
    types.Spawn(_, _) -> "spawn"
    types.Exit(_) -> "exit"
    types.Register(_) -> "register"
    types.Link(_) -> "link"
    types.Metric(_, _) -> "metric"
    types.SystemSignal(_, _) -> "system_signal"
    types.Gap(_, _) -> "gap"
    types.Stop(_) -> "stop"
  }
}

fn success_response(id: RpcId, result: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id_json(id)),
    #("result", result),
  ])
  |> json.to_string
}

fn unsupported_version_response(id: RpcId, requested: String) -> String {
  error_response_with_data(
    Some(id),
    -32_022,
    "Unsupported protocol version",
    json.object([
      #("supported", json.array([modern_protocol_version], json.string)),
      #("requested", json.string(requested)),
    ]),
  )
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

fn error_response_with_data(
  id: Option(RpcId),
  code: Int,
  message: String,
  data: json.Json,
) -> String {
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
        #("data", data),
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
  use id <- decode.optional_field("id", None, id_decoder() |> decode.map(Some))
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

fn modern_metadata_decoder() -> decode.Decoder(String) {
  decode.at(["params", "_meta"], modern_metadata_object_decoder())
}

fn modern_metadata_object_decoder() -> decode.Decoder(String) {
  use protocol_version <- decode.field(
    "io.modelcontextprotocol/protocolVersion",
    decode.string,
  )
  use _capabilities <- decode.field(
    "io.modelcontextprotocol/clientCapabilities",
    decode.dict(decode.string, decode.dynamic),
  )
  use _client_info <- decode.optional_field(
    "io.modelcontextprotocol/clientInfo",
    None,
    implementation_decoder() |> decode.map(Some),
  )
  decode.success(protocol_version)
}

fn implementation_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.string)
  decode.success(#(name, version))
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

fn overview_arguments_decoder() -> decode.Decoder(OverviewArguments) {
  decode.at(["params", "arguments"], overview_arguments_object_decoder())
}

fn overview_arguments_object_decoder() -> decode.Decoder(OverviewArguments) {
  use path <- decode.field("path", decode.string)
  decode.success(OverviewArguments(path))
}

@external(erlang, "beamtrace_mcp_stdio_ffi", "read_line")
fn read_line() -> Input

@external(erlang, "beamtrace_mcp_stdio_ffi", "write_line")
fn write_line(value: String) -> Nil

@external(erlang, "beamtrace_mcp_stdio_ffi", "write_error")
fn write_error(value: String) -> Nil
