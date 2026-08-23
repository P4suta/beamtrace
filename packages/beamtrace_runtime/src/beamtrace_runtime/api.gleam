import beamtrace/codec
import beamtrace_runtime/annotations
import beamtrace_runtime/audit
import beamtrace_runtime/audit_store
import beamtrace_runtime/csrf
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/id_token
import beamtrace_runtime/local_auth
import beamtrace_runtime/oidc
import beamtrace_runtime/oidc_client
import beamtrace_runtime/oidc_flow
import beamtrace_runtime/rbac
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/storage
import beamtrace_runtime/team_auth
import beamtrace_runtime/team_store
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
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

pub type RelayEnrollment {
  RelayEnrollment(store: enrollment_store.Store, channel_origin: String)
}

pub type TeamSecurity {
  TeamSecurity(
    sessions: team_auth.Store,
    annotations: annotations.Store,
    audit: audit_store.Store,
    origin: String,
    oidc: Option(OidcProvider),
    relay_inbox: Option(relay_inbox.Store),
    relay_archive: Option(RelayArchive),
  )
}

pub type RelayArchive {
  RelayArchive(store: team_store.Store, blob_root: String)
}

pub type OidcProvider {
  OidcProvider(
    authorization_endpoint: String,
    client_id: String,
    redirect_uri: String,
    issuer: String,
    jwks_json: String,
    attempts: oidc_flow.Store,
    group_roles: List(#(String, rbac.Role)),
    project: String,
    environment: String,
    exchange: fn(String, String, String) -> Result(String, String),
  )
}

/// Build the production provider boundary. The token transport returns only
/// the signed ID token; verification always uses the preconfigured JWKS held
/// by this provider.
pub fn production_oidc_provider(
  authorization_endpoint authorization_endpoint: String,
  token_endpoint token_endpoint: String,
  client_id client_id: String,
  redirect_uri redirect_uri: String,
  issuer issuer: String,
  jwks_json jwks_json: String,
  attempts attempts: oidc_flow.Store,
  group_roles group_roles: List(#(String, rbac.Role)),
  project project: String,
  environment environment: String,
) -> OidcProvider {
  OidcProvider(
    authorization_endpoint: authorization_endpoint,
    client_id: client_id,
    redirect_uri: redirect_uri,
    issuer: issuer,
    jwks_json: jwks_json,
    attempts: attempts,
    group_roles: group_roles,
    project: project,
    environment: environment,
    exchange: fn(code, verifier, callback_uri) {
      case
        oidc_client.exchange(
          token_endpoint,
          client_id,
          code,
          verifier,
          callback_uri,
        )
      {
        Ok(token) -> Ok(token)
        Error(_) -> Error("token_exchange_failed")
      }
    },
  )
}

pub type Context {
  Context(
    tool_version: String,
    mode: ServerMode,
    static_root: Option(String),
    local_auth: Option(local_auth.Store),
    archive_path: Option(String),
    relay_enrollment: Option(RelayEnrollment),
    team_security: Option(TeamSecurity),
  )
}

pub fn test_context() -> Context {
  Context("0.1.0", Local, None, None, None, None, None)
}

pub fn handle(incoming: wisp.Request, context: Context) -> wisp.Response {
  handle_at(incoming, context, local_auth.now_ms())
}

pub fn handle_at(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  let segments = request.path_segments(incoming)
  let routed = case segments, incoming.method {
    ["api", "v1", "health"], http.Get ->
      wisp.json_response(
        "{\"status\":\"ok\",\"api_version\":\"v1\",\"mode\":\""
          <> mode_name(context.mode)
          <> "\"}",
        200,
      )
    ["api", "v1", "health"], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "capabilities"], http.Get ->
      wisp.json_response(
        "{\"capture\":true,\"live_sampling\":true,\"compare\":true,"
          <> "\"arbitrary_rpc\":false,\"process_kill\":false,"
          <> "\"state_mutation\":false,\"ets_browser\":false}",
        200,
      )
    ["api", "v1", "capabilities"], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "sessions", "current", "events"], http.Get ->
      event_window_response(incoming, context, now_ms)
    ["api", "v1", "sessions", "current", "events"], _ ->
      wisp.method_not_allowed([http.Get])
    ["api", "v1", "sessions", "current", "annotations"], http.Get ->
      list_annotations(incoming, context, now_ms)
    ["api", "v1", "sessions", "current", "annotations"], http.Post ->
      create_annotation(incoming, context, now_ms)
    ["api", "v1", "sessions", "current", "annotations"], _ ->
      wisp.method_not_allowed([http.Get, http.Post])
    ["api", "v1", "audit"], http.Get ->
      audit_response(incoming, context, now_ms)
    ["api", "v1", "audit"], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "relays", relay_id, "frames"], http.Get ->
      relay_frames_response(incoming, context, relay_id, now_ms)
    ["api", "v1", "relays", _, "frames"], _ ->
      wisp.method_not_allowed([http.Get])
    ["api", "relay", "v1", "enroll"], http.Post ->
      relay_enrollment_response(incoming, context, now_ms)
    ["api", "relay", "v1", "enroll"], _ -> wisp.method_not_allowed([http.Post])
    ["auth", "oidc", "start"], http.Get -> oidc_start(context, now_ms)
    ["auth", "oidc", "start"], _ -> wisp.method_not_allowed([http.Get])
    ["auth", "oidc", "callback"], http.Get ->
      oidc_callback(incoming, context, now_ms)
    ["auth", "oidc", "callback"], _ -> wisp.method_not_allowed([http.Get])
    ["bootstrap", token], http.Get -> bootstrap_exchange(context, token, now_ms)
    ["bootstrap", _], _ -> wisp.method_not_allowed([http.Get])
    [], http.Get ->
      authenticated_asset(
        incoming,
        context,
        "index.html",
        "text/html; charset=utf-8",
        now_ms,
      )
    ["styles.css"], http.Get ->
      authenticated_asset(
        incoming,
        context,
        "styles.css",
        "text/css; charset=utf-8",
        now_ms,
      )
    ["beamtrace_web.js"], http.Get ->
      authenticated_asset(
        incoming,
        context,
        "beamtrace_web.js",
        "text/javascript; charset=utf-8",
        now_ms,
      )
    [], _ | ["styles.css"], _ | ["beamtrace_web.js"], _ ->
      wisp.method_not_allowed([http.Get])
    _, _ -> wisp.not_found()
  }
  case segments {
    ["api", ..] -> secure_api(routed)
    _ -> secure_workspace(routed)
  }
}

fn audit_response(
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

fn relay_frames_response(
  incoming: wisp.Request,
  context: Context,
  relay_id: String,
  now_ms: Int,
) -> wisp.Response {
  case context.mode, context.team_security {
    Team, Some(security) ->
      case team_session(incoming, context, now_ms) {
        Error(_) -> wisp.response(401)
        Ok(session) ->
          case rbac.authorize(session.roles, rbac.ViewSession) {
            False -> wisp.response(403)
            True -> relay_frames_for_authorized(incoming, security, relay_id)
          }
      }
    _, _ -> wisp.not_found()
  }
}

fn relay_frames_for_authorized(
  incoming: wisp.Request,
  security: TeamSecurity,
  relay_id: String,
) -> wisp.Response {
  case valid_relay_id(relay_id), relay_pagination(incoming) {
    False, _ -> wisp.not_found()
    _, Error(_) -> wisp.json_response("{\"error\":\"invalid_window\"}", 400)
    True, Ok(page) -> {
      let #(start, limit) = page
      relay_frames_from_sources(security, relay_id, start, limit)
    }
  }
}

fn relay_frames_from_sources(
  security: TeamSecurity,
  relay_id: String,
  start: Int,
  limit: Int,
) -> wisp.Response {
  case security.relay_inbox {
    None ->
      relay_frames_from_archive(security.relay_archive, relay_id, start, limit)
    Some(inbox) ->
      case relay_inbox.window(inbox, relay_id, start:, limit:) {
        Error(_) -> wisp.response(503)
        Ok(window) ->
          case window.total == 0, security.relay_archive {
            True, Some(archive) ->
              relay_frames_from_archive(Some(archive), relay_id, start, limit)
            _, _ -> relay_window_response(window)
          }
      }
  }
}

fn relay_frames_from_archive(
  archive: Option(RelayArchive),
  relay_id: String,
  start: Int,
  limit: Int,
) -> wisp.Response {
  case archive {
    None -> wisp.not_found()
    Some(RelayArchive(store, blob_root)) ->
      case
        team_store.relay_frame_count(store, relay_id),
        team_store.relay_frames(store, relay_id, start:, limit:)
      {
        Ok(total), Ok(frames) ->
          case durable_relay_entries(blob_root, frames) {
            Error(_) -> wisp.response(503)
            Ok(entries) ->
              relay_window_response(relay_inbox.Window(
                entries,
                total,
                start,
                limit,
              ))
          }
        _, _ -> wisp.response(503)
      }
  }
}

fn durable_relay_entries(
  blob_root: String,
  frames: List(team_store.RelayFrameIndex),
) -> Result(List(relay_inbox.Entry), String) {
  case frames {
    [] -> Ok([])
    [frame, ..rest] ->
      case relay_archive.read_payload(blob_root, frame) {
        Error(error) -> Error(error)
        Ok(payload) ->
          case durable_relay_entries(blob_root, rest) {
            Error(error) -> Error(error)
            Ok(entries) ->
              Ok([
                relay_inbox.Payload(
                  frame.sequence,
                  payload,
                  frame.received_at_ms,
                ),
                ..entries
              ])
          }
      }
  }
}

fn relay_window_response(window: relay_inbox.Window) -> wisp.Response {
  wisp.json_response(
    json.object([
      #("start", json.int(window.start)),
      #("limit", json.int(window.limit)),
      #("total", json.int(window.total)),
      #("frames", json.array(window.entries, relay_entry_json)),
    ])
      |> json.to_string,
    200,
  )
}

fn relay_entry_json(entry: relay_inbox.Entry) -> json.Json {
  case entry {
    relay_inbox.Payload(sequence, payload, received_at_ms) ->
      json.object([
        #("kind", json.string("payload")),
        #("sequence", json.int(sequence)),
        #("payload", json.string(payload)),
        #("received_at_ms", json.int(received_at_ms)),
      ])
    relay_inbox.Gap(dropped_frames, reason, received_at_ms) ->
      json.object([
        #("kind", json.string("gap")),
        #("dropped_frames", json.int(dropped_frames)),
        #("reason", json.string(reason)),
        #("received_at_ms", json.int(received_at_ms)),
      ])
  }
}

fn relay_pagination(incoming: wisp.Request) -> Result(#(Int, Int), Nil) {
  case pagination(incoming) {
    Ok(#(start, limit)) if start >= 0 && limit >= 1 && limit <= 200 ->
      Ok(#(start, limit))
    _ -> Error(Nil)
  }
}

fn valid_relay_id(relay_id: String) -> Bool {
  case string.starts_with(relay_id, "relay-") {
    False -> False
    True ->
      case bit_array.base16_decode(string.drop_start(relay_id, 6)) {
        Ok(bytes) -> bit_array.byte_size(bytes) == 12
        Error(_) -> False
      }
  }
}

type EnrollmentPayload {
  EnrollmentPayload(
    protocol_version: Int,
    token: String,
    algorithm: String,
    public_key: String,
  )
}

type AnnotationPayload {
  AnnotationPayload(event_id: String, text: String)
}

fn oidc_start(context: Context, now_ms: Int) -> wisp.Response {
  case context.mode, context.team_security {
    Team, Some(security) ->
      case security.oidc {
        None -> wisp.not_found()
        Some(provider) -> {
          let start = oidc.begin(provider.redirect_uri, now_ms, 5 * 60 * 1000)
          case
            oidc_flow.remember(provider.attempts, start),
            oidc.authorization_url(
              provider.authorization_endpoint,
              provider.client_id,
              provider.redirect_uri,
              oidc.state(start.attempt),
              oidc.nonce(start.attempt),
              oidc.code_challenge(start.attempt),
            )
          {
            Ok(Nil), Ok(location) -> wisp.redirect(location)
            _, _ -> wisp.response(503)
          }
        }
      }
    _, _ -> wisp.not_found()
  }
}

fn oidc_callback(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  case context.mode, context.team_security {
    Team, Some(security) ->
      case security.oidc, oidc_callback_parameters(incoming) {
        None, _ -> wisp.not_found()
        _, Error(_) ->
          wisp.json_response("{\"error\":\"invalid_callback\"}", 400)
        Some(provider), Ok(parameters) -> {
          let #(state, code) = parameters
          case oidc_flow.consume(provider.attempts, state, now_ms) {
            Error("already_used") -> wisp.response(409)
            Error("expired") -> wisp.response(410)
            Error(_) -> wisp.response(403)
            Ok(pending) ->
              exchange_oidc_callback(
                provider,
                security,
                pending,
                state,
                code,
                now_ms,
              )
          }
        }
      }
    _, _ -> wisp.not_found()
  }
}

fn exchange_oidc_callback(
  provider: OidcProvider,
  security: TeamSecurity,
  pending: oidc_flow.Pending,
  state: String,
  code: String,
  now_ms: Int,
) -> wisp.Response {
  case provider.exchange(code, pending.code_verifier, provider.redirect_uri) {
    Error(_) -> {
      audit_login(security, now_ms, "anonymous", "denied_exchange")
      wisp.response(401)
    }
    Ok(token) ->
      case
        id_token.verify(
          token,
          provider.jwks_json,
          provider.issuer,
          provider.client_id,
          oidc.nonce(pending.attempt),
          now_ms / 1000,
        )
      {
        Error(_) -> {
          audit_login(security, now_ms, "anonymous", "denied_token")
          wisp.response(401)
        }
        Ok(claims) ->
          case
            oidc.validate(
              pending.attempt,
              state,
              id_token.nonce(claims),
              pending.code_verifier,
              provider.redirect_uri,
              now_ms,
              oidc.pkce_s256,
            )
          {
            Error(_) -> {
              audit_login(
                security,
                now_ms,
                id_token.subject(claims),
                "denied_claims",
              )
              wisp.response(401)
            }
            Ok(validated) ->
              issue_oidc_session(provider, security, validated, claims, now_ms)
          }
      }
  }
}

fn issue_oidc_session(
  provider: OidcProvider,
  security: TeamSecurity,
  validated: oidc.Attempt,
  claims: id_token.VerifiedClaims,
  now_ms: Int,
) -> wisp.Response {
  let subject = id_token.subject(claims)
  let roles = roles_for_groups(id_token.groups(claims), provider.group_roles)
  case
    team_auth.issue_from_oidc(
      security.sessions,
      validated,
      subject,
      roles,
      provider.project,
      provider.environment,
      now_ms,
      8 * 60 * 60 * 1000,
    )
  {
    Error(_) -> {
      audit_login(security, now_ms, subject, "denied_session")
      wisp.response(401)
    }
    Ok(session) -> {
      audit_login(security, now_ms, subject, "allowed")
      oidc_session_response(session)
    }
  }
}

fn roles_for_groups(
  groups: List(String),
  mappings: List(#(String, rbac.Role)),
) -> List(rbac.Role) {
  list.filter_map(mappings, fn(mapping) {
    case list.contains(groups, mapping.0) {
      True -> Ok(mapping.1)
      False -> Error(Nil)
    }
  })
}

fn oidc_callback_parameters(
  incoming: wisp.Request,
) -> Result(#(String, String), Nil) {
  case request.get_query(incoming) {
    Error(_) -> Error(Nil)
    Ok(query) ->
      case list.key_find(query, "state"), list.key_find(query, "code") {
        Ok(state), Ok(code) -> Ok(#(state, code))
        _, _ -> Error(Nil)
      }
  }
}

fn oidc_session_response(session: team_auth.Session) -> wisp.Response {
  let session_attributes =
    cookie.Attributes(
      max_age: Some(8 * 60 * 60),
      domain: None,
      path: Some("/"),
      secure: True,
      http_only: True,
      same_site: Some(cookie.Strict),
    )
  let csrf_attributes =
    cookie.Attributes(
      max_age: Some(8 * 60 * 60),
      domain: None,
      path: Some("/"),
      secure: True,
      http_only: False,
      same_site: Some(cookie.Strict),
    )
  wisp.redirect("/")
  |> response.set_cookie("beamtrace_session", session.id, session_attributes)
  |> response.set_cookie("beamtrace_csrf", session.csrf_token, csrf_attributes)
  |> response.set_header("clear-site-data", "\"cache\"")
}

fn audit_login(
  security: TeamSecurity,
  now_ms: Int,
  actor: String,
  outcome: String,
) -> Nil {
  audit_store.append(
    security.audit,
    now_ms,
    actor,
    "session.login",
    "oidc",
    outcome,
  )
}

fn relay_enrollment_response(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  case context.mode, context.relay_enrollment {
    Team, Some(configuration) ->
      case read_enrollment_payload(incoming) {
        Error("too_large") -> {
          audit_relay_enrollment(
            context,
            now_ms,
            "anonymous",
            "relay",
            "denied_input",
          )
          wisp.response(413)
        }
        Error(_) -> {
          audit_relay_enrollment(
            context,
            now_ms,
            "anonymous",
            "relay",
            "denied_input",
          )
          wisp.json_response("{\"error\":\"invalid_request\"}", 400)
        }
        Ok(payload) ->
          case
            enrollment_store.consume(
              configuration.store,
              payload.0,
              payload.1,
              now_ms,
            )
          {
            Ok(relay) -> {
              audit_relay_enrollment(
                context,
                now_ms,
                relay.id,
                relay.id,
                "allowed",
              )
              wisp.json_response(
                json.object([
                  #("relay_id", json.string(relay.id)),
                  #(
                    "channel_url",
                    json.string(
                      trim_trailing_slashes(configuration.channel_origin)
                      <> "/api/relay/v1/channel/"
                      <> relay.id,
                    ),
                  ),
                ])
                  |> json.to_string,
                201,
              )
            }
            Error("already_used") -> {
              audit_relay_enrollment(
                context,
                now_ms,
                "anonymous",
                "relay",
                "denied_reuse",
              )
              wisp.json_response("{\"error\":\"already_used\"}", 409)
            }
            Error("expired") -> {
              audit_relay_enrollment(
                context,
                now_ms,
                "anonymous",
                "relay",
                "denied_expired",
              )
              wisp.json_response("{\"error\":\"expired\"}", 410)
            }
            Error("invalid_token") -> {
              audit_relay_enrollment(
                context,
                now_ms,
                "anonymous",
                "relay",
                "denied_token",
              )
              wisp.json_response("{\"error\":\"invalid_token\"}", 403)
            }
            Error(_) -> {
              audit_relay_enrollment(
                context,
                now_ms,
                "anonymous",
                "relay",
                "denied_storage",
              )
              wisp.json_response("{\"error\":\"invalid_request\"}", 400)
            }
          }
      }
    _, _ -> wisp.not_found()
  }
}

fn audit_relay_enrollment(
  context: Context,
  now_ms: Int,
  actor: String,
  resource: String,
  outcome: String,
) -> Nil {
  case context.team_security {
    Some(security) ->
      audit_store.append(
        security.audit,
        now_ms,
        actor,
        "relay.enroll",
        resource,
        outcome,
      )
    None -> Nil
  }
}

fn read_enrollment_payload(
  incoming: wisp.Request,
) -> Result(#(String, BitArray), String) {
  case wisp.read_body_bits(incoming) {
    Error(_) -> Error("too_large")
    Ok(body) ->
      case bit_array.byte_size(body) > 4096, bit_array.to_string(body) {
        True, _ -> Error("too_large")
        _, Error(_) -> Error("invalid_utf8")
        False, Ok(source) -> decode_enrollment_payload(source)
      }
  }
}

fn decode_enrollment_payload(
  source: String,
) -> Result(#(String, BitArray), String) {
  case json.parse(source, enrollment_payload_decoder()) {
    Error(_) -> Error("invalid_json")
    Ok(payload) ->
      case
        payload.protocol_version == 1,
        payload.algorithm == "Ed25519",
        bit_array.base64_url_decode(payload.public_key)
      {
        False, _, _ -> Error("unsupported_protocol")
        _, False, _ -> Error("unsupported_algorithm")
        _, _, Error(_) -> Error("invalid_public_key")
        True, True, Ok(public_key) ->
          case bit_array.byte_size(public_key) == 32 {
            True -> Ok(#(payload.token, public_key))
            False -> Error("invalid_public_key")
          }
      }
  }
}

fn enrollment_payload_decoder() -> decode.Decoder(EnrollmentPayload) {
  use protocol_version <- decode.field("protocol_version", decode.int)
  use token <- decode.field("token", decode.string)
  use algorithm <- decode.field("algorithm", decode.string)
  use public_key <- decode.field("public_key", decode.string)
  decode.success(EnrollmentPayload(
    protocol_version,
    token,
    algorithm,
    public_key,
  ))
}

fn trim_trailing_slashes(source: String) -> String {
  case string.ends_with(source, "/") {
    True -> trim_trailing_slashes(string.drop_end(source, 1))
    False -> source
  }
}

fn event_window_response(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> wisp.Response {
  case authorize_action(incoming, context, now_ms, rbac.ViewSession) {
    False -> wisp.response(401)
    True ->
      case
        context.archive_path,
        pagination(incoming),
        event_search_query(incoming)
      {
        None, _, _ -> wisp.not_found()
        _, Error(_), _ ->
          wisp.json_response("{\"error\":\"invalid_window\"}", 400)
        _, _, Error(_) ->
          wisp.json_response("{\"error\":\"invalid_search\"}", 400)
        Some(path), Ok(page), Ok(search_query) -> {
          let #(start, limit) = page
          let result = case search_query {
            None -> storage.window(path, start:, limit:)
            Some(query) -> storage.search(path, query, start:, limit:)
          }
          case result {
            Ok(window) -> {
              let events =
                window.events
                |> list.map(codec.encode_event)
                |> string.join(",")
              wisp.json_response(
                "{\"start\":"
                  <> int.to_string(window.start)
                  <> ",\"limit\":"
                  <> int.to_string(window.limit)
                  <> ",\"total\":"
                  <> int.to_string(window.total)
                  <> ",\"events\":["
                  <> events
                  <> "]}",
                200,
              )
            }
            Error(storage.InvalidWindow) ->
              wisp.json_response("{\"error\":\"invalid_window\"}", 400)
            Error(storage.InvalidSearch) ->
              wisp.json_response("{\"error\":\"invalid_search\"}", 400)
            Error(_) ->
              wisp.json_response("{\"error\":\"invalid_archive\"}", 422)
          }
        }
      }
  }
}

fn event_search_query(incoming: wisp.Request) -> Result(Option(String), Nil) {
  case request.get_query(incoming) {
    Error(_) -> Error(Nil)
    Ok(query) ->
      case list.key_find(query, "q") {
        Error(_) -> Ok(None)
        Ok(source) -> {
          let normalized = string.trim(source)
          case normalized == "", string.byte_size(normalized) <= 256 {
            True, _ -> Ok(None)
            False, True -> Ok(Some(normalized))
            False, False -> Error(Nil)
          }
        }
      }
  }
}

fn authorize_action(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
  action: rbac.Action,
) -> Bool {
  case context.mode {
    Local -> authorize_local(incoming, context.local_auth, now_ms)
    Team ->
      case team_session(incoming, context, now_ms) {
        Ok(session) -> rbac.authorize(session.roles, action)
        Error(_) -> False
      }
  }
}

fn authorize_local(
  incoming: wisp.Request,
  store: Option(local_auth.Store),
  now_ms: Int,
) -> Bool {
  case store {
    None -> False
    Some(store) ->
      case session_cookie(incoming) {
        Ok(session) -> local_auth.authorize_at(store, session, now_ms)
        Error(_) -> False
      }
  }
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

fn list_annotations(
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
      case rbac.authorize(session.roles, rbac.ViewSession) {
        False -> wisp.response(403)
        True ->
          case annotations.list_result(security.annotations) {
            Error(_) ->
              wisp.json_response(
                "{\"error\":\"annotation_storage_failed\"}",
                503,
              )
            Ok(items) ->
              items
              |> json.array(annotation_json)
              |> json.to_string
              |> wisp.json_response(200)
          }
      }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

fn create_annotation(
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
        rbac.authorize(session.roles, rbac.Annotate),
        valid_team_csrf(incoming, security, session)
      {
        False, _ -> {
          record_annotation_audit(
            security,
            session,
            now_ms,
            "session:current",
            "denied_rbac",
          )
          wisp.response(403)
        }
        True, False -> {
          record_annotation_audit(
            security,
            session,
            now_ms,
            "session:current",
            "denied_csrf",
          )
          wisp.response(403)
        }
        True, True ->
          create_authorized_annotation(incoming, security, session, now_ms)
      }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

fn create_authorized_annotation(
  incoming: wisp.Request,
  security: TeamSecurity,
  session: team_auth.Session,
  now_ms: Int,
) -> wisp.Response {
  case wisp.read_body_bits(incoming) {
    Error(_) -> {
      denied_input(security, session, now_ms)
      wisp.response(413)
    }
    Ok(body) ->
      case bit_array.byte_size(body) > 16_384, bit_array.to_string(body) {
        True, _ -> {
          denied_input(security, session, now_ms)
          wisp.response(413)
        }
        _, Error(_) -> {
          denied_input(security, session, now_ms)
          wisp.json_response("{\"error\":\"invalid_request\"}", 400)
        }
        False, Ok(source) ->
          case json.parse(source, annotation_payload_decoder()) {
            Error(_) -> {
              denied_input(security, session, now_ms)
              wisp.json_response("{\"error\":\"invalid_request\"}", 400)
            }
            Ok(payload) ->
              case
                annotations.append(
                  security.annotations,
                  payload.event_id,
                  payload.text,
                  session.subject,
                  now_ms,
                )
              {
                Error(annotations.StorageError(_)) ->
                  wisp.json_response(
                    "{\"error\":\"annotation_storage_failed\"}",
                    503,
                  )
                Error(_) -> {
                  denied_input(security, session, now_ms)
                  wisp.json_response("{\"error\":\"invalid_annotation\"}", 400)
                }
                Ok(annotation) -> {
                  record_annotation_audit(
                    security,
                    session,
                    now_ms,
                    "event:" <> annotation.event_id,
                    "allowed",
                  )
                  annotation
                  |> annotation_json
                  |> json.to_string
                  |> wisp.json_response(201)
                }
              }
          }
      }
  }
}

fn denied_input(
  security: TeamSecurity,
  session: team_auth.Session,
  now_ms: Int,
) -> Nil {
  record_annotation_audit(
    security,
    session,
    now_ms,
    "session:current",
    "denied_input",
  )
}

fn record_annotation_audit(
  security: TeamSecurity,
  session: team_auth.Session,
  now_ms: Int,
  resource: String,
  outcome: String,
) -> Nil {
  audit_store.append(
    security.audit,
    now_ms,
    session.subject,
    "annotation.create",
    resource,
    outcome,
  )
}

fn annotation_payload_decoder() -> decode.Decoder(AnnotationPayload) {
  use event_id <- decode.field("event_id", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(AnnotationPayload(event_id, text))
}

fn annotation_json(annotation: annotations.Annotation) -> json.Json {
  json.object([
    #("id", json.string(annotation.id)),
    #("event_id", json.string(annotation.event_id)),
    #("text", json.string(annotation.text)),
    #("author", json.string(annotation.author)),
    #("created_at_ms", json.int(annotation.created_at_ms)),
  ])
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

fn authenticated_asset(
  incoming: wisp.Request,
  context: Context,
  filename: String,
  content_type: String,
  now_ms: Int,
) -> wisp.Response {
  case context.mode, context.local_auth {
    Team, _ ->
      case authorize_action(incoming, context, now_ms, rbac.ViewSession) {
        True -> static_asset(context, filename, content_type)
        False -> wisp.response(401)
      }
    Local, None -> static_asset(context, filename, content_type)
    Local, Some(_) ->
      case authorize_action(incoming, context, now_ms, rbac.ViewSession) {
        True -> static_asset(context, filename, content_type)
        False -> wisp.response(401)
      }
  }
}

fn bootstrap_exchange(
  context: Context,
  token: String,
  now_ms: Int,
) -> wisp.Response {
  case context.local_auth {
    None -> wisp.not_found()
    Some(store) ->
      case local_auth.exchange(store, token, now_ms) {
        Error(_) -> wisp.response(403)
        Ok(session) -> {
          let attributes =
            cookie.Attributes(
              max_age: Some(8 * 60 * 60),
              domain: None,
              path: Some("/"),
              secure: context.mode == Team,
              http_only: True,
              same_site: Some(cookie.Strict),
            )
          wisp.redirect(to: "/")
          |> response.set_cookie("beamtrace_session", session.id, attributes)
          |> response.set_header("clear-site-data", "\"cache\"")
        }
      }
  }
}

fn static_asset(
  context: Context,
  filename: String,
  content_type: String,
) -> wisp.Response {
  case context.static_root {
    None -> wisp.not_found()
    Some(root) ->
      wisp.response(200)
      |> response.set_header("content-type", content_type)
      |> wisp.set_body(wisp.File(
        path: root <> "/" <> filename,
        offset: 0,
        limit: None,
      ))
  }
}

fn common_security(outgoing: wisp.Response) -> wisp.Response {
  outgoing
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("cross-origin-resource-policy", "same-origin")
}

fn secure_api(outgoing: wisp.Response) -> wisp.Response {
  outgoing
  |> common_security
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; frame-ancestors 'none'",
  )
}

fn secure_workspace(outgoing: wisp.Response) -> wisp.Response {
  outgoing
  |> common_security
  |> response.set_header(
    "content-security-policy",
    "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; font-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
  )
}

fn mode_name(mode: ServerMode) -> String {
  case mode {
    Local -> "local"
    Team -> "team"
  }
}
