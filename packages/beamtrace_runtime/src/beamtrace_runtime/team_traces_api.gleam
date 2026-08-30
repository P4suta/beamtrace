import beamtrace/codec
import beamtrace/types
import beamtrace_runtime/audit
import beamtrace_runtime/audit_store
import beamtrace_runtime/blob_store
import beamtrace_runtime/compare_workspace
import beamtrace_runtime/csrf
import beamtrace_runtime/local_api
import beamtrace_runtime/rbac
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_payload
import beamtrace_runtime/team_auth
import beamtrace_runtime/team_store
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import wisp

pub type ServerMode {
  Local
  Team
}

pub type RelayArchive {
  RelayArchive(store: team_store.Store, backend: blob_store.Backend)
}

pub type TeamSecurity {
  TeamSecurity(
    sessions: team_auth.Store,
    audit: audit_store.Store,
    origin: String,
    relay_archive: Option(RelayArchive),
  )
}

pub type Context {
  Context(mode: ServerMode, team_security: Option(TeamSecurity))
}

type ComparePayload {
  ComparePayload(paths: List(String))
}

/// Compare 2–20 Team traces after applying the same session and raw-content
/// authorization used by the event endpoint. Decoded events never bypass the
/// checked DAG preparation path.
pub fn compare_response(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  case
    context.mode,
    context.team_security,
    team_session(incoming, context, now_ms)
  {
    Team, Some(security), Ok(session) ->
      case valid_team_csrf(incoming, security, session) {
        False -> wisp.response(403)
        True ->
          case
            rbac.authorize(session.roles, rbac.ViewSession),
            security.relay_archive,
            decode_compare_body(incoming)
          {
            False, _, _ -> wisp.response(403)
            _, None, _ -> wisp.response(503)
            _, _, Error("too_large") -> wisp.response(413)
            _, _, Error(_) ->
              wisp.json_response("{\"error\":\"invalid_request\"}", 400)
            True, Some(archive), Ok(ComparePayload(paths)) -> {
              let #(store, backend) = relay_archive_parts(archive)
              case team_compare_ids(paths) {
                Error(_) ->
                  wisp.json_response("{\"error\":\"invalid_paths\"}", 400)
                Ok(ids) ->
                  case
                    load_compare_runs(
                      store,
                      backend,
                      security,
                      session,
                      ids,
                      now_ms,
                      [],
                    )
                  {
                    Error("not_found") -> wisp.not_found()
                    Error("permission_denied") -> wisp.response(403)
                    Error("too_many_events") -> wisp.response(413)
                    Error(_) -> wisp.response(503)
                    Ok(runs) ->
                      case compare_workspace.compare_events(runs) {
                        Error(compare_workspace.InvalidPaths) ->
                          wisp.json_response(
                            "{\"error\":\"invalid_paths\"}",
                            400,
                          )
                        Error(compare_workspace.InvalidTrace(path, _)) ->
                          json.object([
                            #("error", json.string("invalid_trace_graph")),
                            #("path", json.string(path)),
                          ])
                          |> json.to_string
                          |> wisp.json_response(422)
                        Error(compare_workspace.LoadFailed(_, _)) ->
                          wisp.response(503)
                        Ok(report) ->
                          report
                          |> local_api.compare_report_json
                          |> json.to_string
                          |> wisp.json_response(200)
                      }
                  }
              }
            }
          }
      }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

fn decode_compare_body(
  incoming: wisp.Request,
) -> Result(ComparePayload, String) {
  case wisp.read_body_bits(incoming) {
    Error(_) -> Error("too_large")
    Ok(body) ->
      case bit_array.byte_size(body) > 16_384, bit_array.to_string(body) {
        True, _ -> Error("too_large")
        _, Error(_) -> Error("invalid_utf8")
        False, Ok(source) ->
          case json.parse(source, compare_payload_decoder()) {
            Ok(payload) -> Ok(payload)
            Error(_) -> Error("invalid_json")
          }
      }
  }
}

fn compare_payload_decoder() -> decode.Decoder(ComparePayload) {
  use paths <- decode.field("paths", decode.list(decode.string))
  decode.success(ComparePayload(paths))
}

fn team_compare_ids(paths: List(String)) -> Result(List(String), Nil) {
  let count = list.length(paths)
  case count >= 2 && count <= 20 {
    False -> Error(Nil)
    True ->
      paths
      |> list.map(fn(path) {
        case string.starts_with(path, "team:") {
          True -> {
            let id = string.drop_start(path, 5)
            case id != "" && string.byte_size(id) <= 256 {
              True -> Ok(id)
              False -> Error(Nil)
            }
          }
          False -> Error(Nil)
        }
      })
      |> collect_results([])
  }
}

fn load_compare_runs(
  store: team_store.Store,
  backend: blob_store.Backend,
  security: TeamSecurity,
  session: team_auth.Session,
  ids: List(String),
  now_ms: Int,
  accumulator: List(#(String, List(types.TraceEvent))),
) -> Result(List(#(String, List(types.TraceEvent))), String) {
  case ids {
    [] -> Ok(list.reverse(accumulator))
    [id, ..rest] ->
      case team_store.trace_session(store, id) {
        Error(_) -> Error("storage_failed")
        Ok(None) -> Error("not_found")
        Ok(Some(trace)) ->
          case authorize_trace_contents(security, session, trace, now_ms) {
            False -> Error("permission_denied")
            True ->
              case trace.event_count > 100_000 {
                True -> Error("too_many_events")
                False ->
                  case load_complete_trace(store, backend, trace, 0, []) {
                    Error(error) -> Error(error)
                    Ok(events) ->
                      load_compare_runs(
                        store,
                        backend,
                        security,
                        session,
                        rest,
                        now_ms,
                        [#("team:" <> id, events), ..accumulator],
                      )
                  }
              }
          }
      }
  }
}

fn load_complete_trace(
  store: team_store.Store,
  backend: blob_store.Backend,
  trace: team_store.TraceSession,
  start: Int,
  accumulator: List(types.TraceEvent),
) -> Result(List(types.TraceEvent), String) {
  case start >= trace.event_count {
    True -> Ok(list.reverse(accumulator))
    False -> {
      let limit = int.min(200, trace.event_count - start)
      case team_store.segments_in_window(store, trace.id, start:, limit:) {
        Error(error) -> Error(error)
        Ok([]) -> Error("missing_trace_segment")
        Ok(segments) ->
          case load_trace_segments(store, backend, trace, segments, []) {
            Error(error) -> Error(error)
            Ok(segment_events) -> {
              let first_event = case segments {
                [first, ..] -> first.first_event
                [] -> start
              }
              let page =
                segment_events
                |> list.drop(int.max(0, start - first_event))
                |> list.take(limit)
              case page {
                [] -> Error("missing_trace_events")
                _ -> {
                  let next_accumulator =
                    list.fold(page, accumulator, fn(events, event) {
                      [event, ..events]
                    })
                  load_complete_trace(
                    store,
                    backend,
                    trace,
                    start + list.length(page),
                    next_accumulator,
                  )
                }
              }
            }
          }
      }
    }
  }
}

fn collect_results(
  results: List(Result(a, e)),
  accumulator: List(a),
) -> Result(List(a), e) {
  case results {
    [] -> Ok(list.reverse(accumulator))
    [Ok(value), ..rest] -> collect_results(rest, [value, ..accumulator])
    [Error(error), ..] -> Error(error)
  }
}

pub fn audit_response(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  case
    context.mode,
    context.team_security,
    team_session(incoming, context, now_ms)
  {
    Team, Some(security), Ok(session) ->
      case
        rbac.authorize(session.roles, rbac.ManageProject),
        pagination(incoming)
      {
        False, _ -> wisp.response(403)
        True, Error(_) ->
          wisp.json_response("{\"error\":\"invalid_window\"}", 400)
        True, Ok(#(_, limit)) if limit > 200 ->
          wisp.json_response("{\"error\":\"invalid_window\"}", 400)
        True, Ok(#(start, limit)) -> {
          let log = audit_store.snapshot(security.audit)
          let entries = log.entries |> list.drop(start) |> list.take(limit)
          json.object([
            #("total", json.int(list.length(log.entries))),
            #("start", json.int(start)),
            #("head_hash", json.string(log.head_hash)),
            #("entries", json.array(entries, audit_entry_json)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
        }
      }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

fn audit_entry_json(entry: audit.AuditEntry) -> json.Json {
  json.object([
    #("sequence", json.int(entry.sequence)),
    #("timestamp_ms", json.int(entry.timestamp_ms)),
    #("actor", json.string(entry.actor)),
    #("action", json.string(entry.action)),
    #("resource", json.string(entry.resource)),
    #("outcome", json.string(entry.outcome)),
    #("previous_hash", json.string(entry.previous_hash)),
    #("hash", json.string(entry.hash)),
  ])
}

pub fn traces_response(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  case
    context.mode,
    context.team_security,
    team_session(incoming, context, now_ms)
  {
    Team, Some(security), Ok(session) ->
      case
        rbac.authorize(session.roles, rbac.ViewSession),
        trace_page(incoming, 50, 100)
      {
        False, _ -> wisp.response(403)
        _, Error(_) -> wisp.json_response("{\"error\":\"invalid_cursor\"}", 400)
        True, Ok(#(start, limit)) ->
          case security.relay_archive {
            None -> wisp.response(503)
            Some(archive) -> {
              let #(store, _) = relay_archive_parts(archive)
              case team_store.trace_sessions(store, start:, limit: limit + 1) {
                Error(_) -> wisp.response(503)
                Ok(traces) -> {
                  let page = list.take(traces, limit)
                  let next = case list.length(traces) > limit {
                    True -> Some(encode_trace_cursor(start + list.length(page)))
                    False -> None
                  }
                  json.object([
                    #(
                      "traces",
                      json.array(page, fn(trace) {
                        trace_session_json(
                          trace,
                          rbac.authorize(session.roles, rbac.ViewRawTrace),
                        )
                      }),
                    ),
                    #("next_cursor", cursor_json(next)),
                  ])
                  |> json.to_string
                  |> wisp.json_response(200)
                }
              }
            }
          }
      }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

pub fn trace_detail_response(
  incoming: wisp.Request,
  context: Context,
  trace_id: String,
  now_ms: Int,
) -> wisp.Response {
  case
    context.mode,
    context.team_security,
    team_session(incoming, context, now_ms)
  {
    Team, Some(security), Ok(session) ->
      case
        rbac.authorize(session.roles, rbac.ViewSession),
        security.relay_archive
      {
        False, _ -> wisp.response(403)
        _, None -> wisp.response(503)
        True, Some(archive) -> {
          let #(store, _) = relay_archive_parts(archive)
          case team_store.trace_session(store, trace_id) {
            Error("invalid_session_id") | Ok(None) -> wisp.not_found()
            Error(_) -> wisp.response(503)
            Ok(Some(trace)) ->
              trace_session_json(
                trace,
                rbac.authorize(session.roles, rbac.ViewRawTrace),
              )
              |> json.to_string
              |> wisp.json_response(200)
          }
        }
      }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

pub fn trace_events_response(
  incoming: wisp.Request,
  context: Context,
  trace_id: String,
  now_ms: Int,
) -> wisp.Response {
  case
    context.mode,
    context.team_security,
    team_session(incoming, context, now_ms)
  {
    Team, Some(security), Ok(session) ->
      case
        rbac.authorize(session.roles, rbac.ViewSession),
        security.relay_archive,
        trace_page(incoming, 200, 200)
      {
        False, _, _ -> wisp.response(403)
        _, None, _ -> wisp.response(503)
        _, _, Error(_) ->
          wisp.json_response("{\"error\":\"invalid_cursor\"}", 400)
        True, Some(archive), Ok(#(start, limit)) -> {
          let #(store, backend) = relay_archive_parts(archive)
          case team_store.trace_session(store, trace_id) {
            Error("invalid_session_id") | Ok(None) -> wisp.not_found()
            Error(_) -> wisp.response(503)
            Ok(Some(trace)) ->
              case start <= trace.event_count {
                False ->
                  wisp.json_response("{\"error\":\"invalid_cursor\"}", 400)
                True ->
                  case
                    authorize_trace_contents(security, session, trace, now_ms)
                  {
                    False -> wisp.response(403)
                    True ->
                      trace_event_page(store, backend, trace, start, limit)
                  }
              }
          }
        }
      }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

fn trace_event_page(
  store: team_store.Store,
  backend: blob_store.Backend,
  trace: team_store.TraceSession,
  start: Int,
  limit: Int,
) -> wisp.Response {
  case team_store.segments_in_window(store, trace.id, start:, limit:) {
    Error(_) -> wisp.response(503)
    Ok([]) if start < trace.event_count -> wisp.response(503)
    Ok([first, ..]) if first.first_event > start -> wisp.response(503)
    Ok(segments) -> {
      case load_trace_segments(store, backend, trace, segments, []) {
        Error(_) -> wisp.response(503)
        Ok(events) -> {
          let first_event = case segments {
            [] -> start
            [first, ..] -> first.first_event
          }
          let page =
            events
            |> list.drop(int.max(0, start - first_event))
            |> list.take(limit)
          let next = case start + list.length(page) < trace.event_count {
            True -> Some(encode_trace_cursor(start + list.length(page)))
            False -> None
          }
          let encoded = page |> list.map(codec.encode_event) |> string.join(",")
          wisp.json_response(
            "{\"trace_id\":"
              <> json.to_string(json.string(trace.id))
              <> ",\"events\":["
              <> encoded
              <> "],\"next_cursor\":"
              <> json.to_string(cursor_json(next))
              <> "}",
            200,
          )
        }
      }
    }
  }
}

fn load_trace_segments(
  store: team_store.Store,
  backend: blob_store.Backend,
  trace: team_store.TraceSession,
  segments: List(team_store.SegmentIndex),
  accumulator: List(types.TraceEvent),
) -> Result(List(types.TraceEvent), String) {
  case segments {
    [] -> Ok(accumulator)
    [segment, ..rest] ->
      case team_store.session_frame(store, trace.id, segment.ordinal) {
        Error(error) -> Error(error)
        Ok(None) -> Error("missing_trace_frame")
        Ok(Some(frame)) ->
          case relay_archive.read_payload_with(backend, frame) {
            Error(error) -> Error(error)
            Ok(payload) ->
              case decode_stored_trace_payload(payload, frame.privacy) {
                Error(error) -> Error(error)
                Ok(batch) ->
                  load_trace_segments(
                    store,
                    backend,
                    trace,
                    rest,
                    list.append(accumulator, batch.events),
                  )
              }
          }
      }
  }
}

fn decode_stored_trace_payload(
  payload: String,
  privacy: String,
) -> Result(relay_payload.Batch, String) {
  case privacy {
    "metadata" | "raw" -> relay_payload.decode_stored(payload, privacy)
    "unknown" ->
      case relay_payload.decode_stored(payload, "metadata") {
        Ok(batch) -> Ok(batch)
        Error(_) -> relay_payload.decode_stored(payload, "raw")
      }
    _ -> Error("invalid_trace_privacy")
  }
}

fn authorize_trace_contents(
  security: TeamSecurity,
  session: team_auth.Session,
  trace: team_store.TraceSession,
  now_ms: Int,
) -> Bool {
  case trace.privacy {
    "metadata" -> True
    _ -> {
      let allowed = rbac.authorize(session.roles, rbac.ViewRawTrace)
      audit_store.append(
        security.audit,
        now_ms,
        session.subject,
        "raw_trace.read",
        "trace:" <> trace.id,
        case allowed {
          True -> "allowed"
          False -> "denied_rbac"
        },
      )
      allowed
    }
  }
}

pub fn trace_hold_response(
  incoming: wisp.Request,
  context: Context,
  trace_id: String,
  now_ms: Int,
) -> wisp.Response {
  case
    context.mode,
    context.team_security,
    team_session(incoming, context, now_ms)
  {
    Team, Some(security), Ok(session) -> {
      let action = case incoming.method {
        http.Post -> "trace.hold.create"
        http.Delete -> "trace.hold.delete"
        _ -> "trace.hold"
      }
      let permitted = rbac.authorize(session.roles, rbac.ManageRetention)
      let csrf_valid = valid_team_csrf(incoming, security, session)
      let outcome = case permitted, csrf_valid {
        False, _ -> Error("denied_rbac")
        _, False -> Error("denied_csrf")
        True, True ->
          case security.relay_archive {
            None -> Error("denied_storage")
            Some(archive) -> {
              let #(store, _) = relay_archive_parts(archive)
              case
                audit_store.append_transactional(
                  security.audit,
                  now_ms,
                  session.subject,
                  action,
                  "trace:" <> trace_id,
                  "allowed",
                  fn(next_log) {
                    team_store.set_trace_legal_hold_audited(
                      store,
                      trace_id,
                      incoming.method == http.Post,
                      next_log,
                    )
                  },
                )
              {
                Ok(trace) -> Ok(trace)
                Error("unknown_session") -> Error("unknown_session")
                Error(_) -> Error("denied_storage")
              }
            }
          }
      }
      case outcome {
        Error(reason) -> {
          audit_trace_hold(security, session, action, trace_id, reason, now_ms)
          case reason {
            "denied_rbac" | "denied_csrf" -> wisp.response(403)
            "unknown_session" -> wisp.not_found()
            _ -> wisp.response(503)
          }
        }
        Ok(trace) -> {
          trace_session_json(trace, True)
          |> json.to_string
          |> wisp.json_response(200)
        }
      }
    }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

fn audit_trace_hold(
  security: TeamSecurity,
  session: team_auth.Session,
  action: String,
  trace_id: String,
  outcome: String,
  now_ms: Int,
) -> Nil {
  audit_store.append(
    security.audit,
    now_ms,
    session.subject,
    action,
    "trace:" <> trace_id,
    outcome,
  )
}

fn trace_session_json(
  trace: team_store.TraceSession,
  raw_allowed: Bool,
) -> json.Json {
  let locked = trace.privacy != "metadata" && !raw_allowed
  json.object([
    #("id", json.string(trace.id)),
    #(
      "status",
      json.string(case trace.active {
        True -> "active"
        False -> trace.delivery_status
      }),
    ),
    #("relay_id", json.string(trace.relay_id)),
    #("project", json.string(trace.project)),
    #("environment", json.string(trace.environment)),
    #("node", json.string(trace.node)),
    #(
      "mfa",
      json.object([
        #("module", json.string(trace.module_)),
        #("function", json.string(trace.function_)),
        #("arity", json.int(trace.arity)),
      ]),
    ),
    #("mode", json.string(trace.mode)),
    #("privacy", json.string(trace.privacy)),
    #("locked", json.bool(locked)),
    #("delivery_status", json.string(trace.delivery_status)),
    #("event_count", json.int(trace.event_count)),
    #("started_at_ms", json.int(trace.started_at_ms)),
    #("received_at_ms", json.int(trace.received_at_ms)),
    #("ended_at_ms", case trace.ended_at_ms {
      0 -> json.null()
      value -> json.int(value)
    }),
    #("last_received_at_ms", json.int(trace.last_received_at_ms)),
    #("legal_hold", json.bool(trace.legal_hold)),
  ])
}

fn trace_page(
  incoming: wisp.Request,
  default_limit: Int,
  maximum_limit: Int,
) -> Result(#(Int, Int), Nil) {
  case request.get_query(incoming) {
    Error(_) -> Error(Nil)
    Ok(query) ->
      case
        int.parse(query_value(query, "limit", int.to_string(default_limit)))
      {
        Ok(limit) if limit > 0 && limit <= maximum_limit ->
          case list.key_find(query, "cursor") {
            Error(_) -> Ok(#(0, limit))
            Ok(cursor) ->
              case decode_trace_cursor(cursor) {
                Ok(start) -> Ok(#(start, limit))
                Error(_) -> Error(Nil)
              }
          }
        _ -> Error(Nil)
      }
  }
}

fn encode_trace_cursor(offset: Int) -> String {
  offset
  |> int.to_string
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}

fn decode_trace_cursor(cursor: String) -> Result(Int, Nil) {
  case string.byte_size(cursor) > 64, bit_array.base64_url_decode(cursor) {
    True, _ | _, Error(_) -> Error(Nil)
    False, Ok(bits) ->
      case bit_array.to_string(bits) {
        Error(_) -> Error(Nil)
        Ok(source) ->
          case int.parse(source) {
            Ok(offset) if offset >= 0 -> Ok(offset)
            _ -> Error(Nil)
          }
      }
  }
}

fn cursor_json(cursor: Option(String)) -> json.Json {
  case cursor {
    None -> json.null()
    Some(value) -> json.string(value)
  }
}

fn relay_archive_parts(
  archive: RelayArchive,
) -> #(team_store.Store, blob_store.Backend) {
  let RelayArchive(store, backend) = archive
  #(store, backend)
}

fn team_session(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> Result(team_auth.Session, Nil) {
  case context.team_security, session_cookie(incoming) {
    Some(security), Ok(session_id) ->
      case team_auth.authorize_at(security.sessions, session_id, now_ms) {
        Ok(session) -> Ok(session)
        Error(_) -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

fn session_cookie(incoming: wisp.Request) -> Result(String, Nil) {
  incoming
  |> request.get_cookies
  |> list.key_find("beamtrace_session")
}

fn valid_team_csrf(
  incoming: wisp.Request,
  security: TeamSecurity,
  session: team_auth.Session,
) -> Bool {
  let csrf_cookie =
    incoming
    |> request.get_cookies
    |> list.key_find("beamtrace_csrf")
  case
    request.get_header(incoming, "origin"),
    request.get_header(incoming, "x-beamtrace-csrf"),
    csrf_cookie
  {
    Ok(origin), Ok(header), Ok(cookie) if cookie == session.csrf_token ->
      csrf.authorize(
        csrf.Post,
        Some(origin),
        security.origin,
        Some(cookie),
        Some(header),
      )
      == Ok(Nil)
    _, _, _ -> False
  }
}

fn pagination(incoming: wisp.Request) -> Result(#(Int, Int), Nil) {
  case request.get_query(incoming) {
    Error(_) -> Error(Nil)
    Ok(query) ->
      case
        int.parse(query_value(query, "start", "0")),
        int.parse(query_value(query, "limit", "200"))
      {
        Ok(start), Ok(limit) -> Ok(#(start, limit))
        _, _ -> Error(Nil)
      }
  }
}

fn query_value(
  query: List(#(String, String)),
  key: String,
  default: String,
) -> String {
  case list.key_find(query, key) {
    Ok(value) -> value
    Error(_) -> default
  }
}
