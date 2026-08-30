import beamtrace/types
import beamtrace_runtime/annotations
import beamtrace_runtime/audit_store
import beamtrace_runtime/csrf
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/id_token
import beamtrace_runtime/oidc
import beamtrace_runtime/oidc_discovery
import beamtrace_runtime/oidc_flow
import beamtrace_runtime/raw_grant
import beamtrace_runtime/rbac
import beamtrace_runtime/relay_channel
import beamtrace_runtime/team_auth
import beamtrace_runtime/team_store
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
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

pub type TeamSecurity {
  TeamSecurity(
    sessions: team_auth.Store,
    annotations: annotations.Store,
    audit: audit_store.Store,
    origin: String,
    oidc: Option(OidcProvider),
    relay_archive: Option(team_store.Store),
  )
}

pub type Context {
  Context(
    mode: ServerMode,
    relay_enrollment: Option(RelayEnrollment),
    team_security: Option(TeamSecurity),
  )
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

type RawCaptureAuthorizationPayload {
  RawCaptureAuthorizationPayload(
    relay_id: String,
    duration_ms: Int,
    max_events: Int,
    max_bytes: Int,
    redact_keys: List(String),
    max_depth: Int,
    max_binary_bytes: Int,
  )
}

pub fn oidc_start(context: Context, now_ms: Int) -> wisp.Response {
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

pub fn oidc_callback(
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
        id_token.verify_with_refresh(
          token,
          oidc_discovery.current_jwks(provider.issuer, provider.jwks_json),
          provider.issuer,
          provider.client_id,
          oidc.nonce(pending.attempt),
          now_ms / 1000,
          fn() { oidc_discovery.refresh_jwks(provider.issuer) },
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

pub fn relay_enrollment_response(
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
        payload.protocol_version == relay_channel.protocol_version
        || payload.protocol_version == 2,
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

pub fn raw_capture_authorization_response(
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
        rbac.authorize(session.roles, rbac.RawCapture),
        valid_team_csrf(incoming, security, session)
      {
        False, _ -> {
          record_raw_capture_audit(
            security,
            session,
            now_ms,
            "raw-capture",
            "denied_rbac",
          )
          wisp.response(403)
        }
        True, False -> {
          record_raw_capture_audit(
            security,
            session,
            now_ms,
            "raw-capture",
            "denied_csrf",
          )
          wisp.response(403)
        }
        True, True ->
          issue_raw_capture_grant(incoming, security, session, now_ms)
      }
    Team, Some(_), Error(_) -> wisp.response(401)
    _, _, _ -> wisp.not_found()
  }
}

fn issue_raw_capture_grant(
  incoming: wisp.Request,
  security: TeamSecurity,
  session: team_auth.Session,
  now_ms: Int,
) -> wisp.Response {
  case security.relay_archive {
    None -> {
      record_raw_capture_audit(
        security,
        session,
        now_ms,
        "raw-capture",
        "denied_storage",
      )
      wisp.json_response("{\"error\":\"raw_capture_unavailable\"}", 503)
    }
    Some(store) -> {
      case wisp.read_body_bits(incoming) {
        Error(_) -> invalid_raw_capture_request(security, session, now_ms, 413)
        Ok(body) ->
          case bit_array.byte_size(body) > 16_384, bit_array.to_string(body) {
            True, _ ->
              invalid_raw_capture_request(security, session, now_ms, 413)
            _, Error(_) ->
              invalid_raw_capture_request(security, session, now_ms, 400)
            False, Ok(source) ->
              case json.parse(source, raw_capture_authorization_decoder()) {
                Error(_) ->
                  invalid_raw_capture_request(security, session, now_ms, 400)
                Ok(payload) ->
                  create_raw_capture_grant(
                    store,
                    security,
                    session,
                    payload,
                    now_ms,
                  )
              }
          }
      }
    }
  }
}

fn create_raw_capture_grant(
  store: team_store.Store,
  security: TeamSecurity,
  session: team_auth.Session,
  payload: RawCaptureAuthorizationPayload,
  now_ms: Int,
) -> wisp.Response {
  let policy =
    types.RawPolicy(
      payload.redact_keys,
      payload.max_depth,
      payload.max_binary_bytes,
    )
  let issued = case team_store.relay_identity_exists(store, payload.relay_id) {
    Ok(True) ->
      raw_grant.issue(
        store,
        relay_id: payload.relay_id,
        actor: session.subject,
        now_ms: now_ms,
        duration_ms: payload.duration_ms,
        max_events: payload.max_events,
        max_bytes: payload.max_bytes,
        policy: policy,
      )
    Ok(False) | Error(_) -> Error("invalid_raw_capture_grant")
  }
  case issued {
    Error(_) -> invalid_raw_capture_request(security, session, now_ms, 400)
    Ok(issued) -> {
      record_raw_capture_audit(
        security,
        session,
        now_ms,
        "relay:" <> issued.relay_id,
        "allowed",
      )
      json.object([
        #("grant", json.string(issued.token)),
        #("relay_id", json.string(issued.relay_id)),
        #("expires_at_ms", json.int(issued.expires_at_ms)),
        #("max_events", json.int(issued.max_events)),
        #("max_bytes", json.int(issued.max_bytes)),
        #(
          "policy",
          json.object([
            #("redact_keys", json.array(issued.policy.redact_keys, json.string)),
            #("max_depth", json.int(issued.policy.max_depth)),
            #("max_binary_bytes", json.int(issued.policy.max_binary_bytes)),
          ]),
        ),
      ])
      |> json.to_string
      |> wisp.json_response(201)
    }
  }
}

fn invalid_raw_capture_request(
  security: TeamSecurity,
  session: team_auth.Session,
  now_ms: Int,
  status: Int,
) -> wisp.Response {
  record_raw_capture_audit(
    security,
    session,
    now_ms,
    "raw-capture",
    "denied_input",
  )
  wisp.json_response("{\"error\":\"invalid_raw_capture_request\"}", status)
}

fn record_raw_capture_audit(
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
    "raw_capture.authorize",
    resource,
    outcome,
  )
}

fn raw_capture_authorization_decoder() -> decode.Decoder(
  RawCaptureAuthorizationPayload,
) {
  use relay_id <- decode.field("relay_id", decode.string)
  use duration_ms <- decode.field("duration_ms", decode.int)
  use max_events <- decode.field("max_events", decode.int)
  use max_bytes <- decode.field("max_bytes", decode.int)
  use redact_keys <- decode.field("redact_keys", decode.list(decode.string))
  use max_depth <- decode.field("max_depth", decode.int)
  use max_binary_bytes <- decode.field("max_binary_bytes", decode.int)
  decode.success(RawCaptureAuthorizationPayload(
    relay_id,
    duration_ms,
    max_events,
    max_bytes,
    redact_keys,
    max_depth,
    max_binary_bytes,
  ))
}

pub fn list_annotations(
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

pub fn create_annotation(
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
