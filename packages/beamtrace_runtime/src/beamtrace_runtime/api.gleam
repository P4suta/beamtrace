import beamtrace_runtime/annotations
import beamtrace_runtime/audit_store
import beamtrace_runtime/blob_store
import beamtrace_runtime/capture_session
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/internal/version as runtime_version
import beamtrace_runtime/local_api
import beamtrace_runtime/local_auth
import beamtrace_runtime/oidc_client
import beamtrace_runtime/oidc_flow
import beamtrace_runtime/rbac
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/team_auth
import beamtrace_runtime/team_auth_api
import beamtrace_runtime/team_store
import beamtrace_runtime/team_traces_api
import gleam/http
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
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
  RelayArchiveBackend(store: team_store.Store, backend: blob_store.Backend)
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
    local_capture: Option(capture_session.Store),
  )
}

pub fn test_context() -> Context {
  Context(runtime_version.current, Local, None, None, None, None, None, None)
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
    ["api", "v1", "ready"], http.Get ->
      wisp.json_response("{\"status\":\"ready\"}", 200)
    ["api", "v1", "ready"], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "capabilities"], http.Get ->
      wisp.json_response(
        "{\"capture\":true,\"live_sampling\":true,\"compare\":true,"
          <> "\"arbitrary_rpc\":false,\"process_kill\":false,"
          <> "\"state_mutation\":false,\"ets_browser\":false}",
        200,
      )
    ["api", "v1", "capabilities"], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "live"], http.Get ->
      local_api.live_snapshot_response(
        incoming,
        local_api_context(incoming, context, now_ms),
        now_ms,
      )
    ["api", "v1", "live"], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "compare"], http.Post ->
      local_api.compare_response(
        incoming,
        local_api_context(incoming, context, now_ms),
        now_ms,
      )
    ["api", "v1", "compare"], _ -> wisp.method_not_allowed([http.Post])
    ["api", "v1", "sessions", "current"], http.Get ->
      local_api.capture_status_response(
        incoming,
        local_api_context(incoming, context, now_ms),
        now_ms,
      )
    ["api", "v1", "sessions", "current"], _ ->
      wisp.method_not_allowed([http.Get])
    ["api", "v1", "sessions", "current", "arm"], http.Post ->
      local_api.capture_arm_response(
        incoming,
        local_api_context(incoming, context, now_ms),
        now_ms,
      )
    ["api", "v1", "sessions", "current", "arm"], _ ->
      wisp.method_not_allowed([http.Post])
    ["api", "v1", "sessions", "current", "cancel"], http.Post ->
      local_api.capture_cancel_response(
        incoming,
        local_api_context(incoming, context, now_ms),
        now_ms,
      )
    ["api", "v1", "sessions", "current", "cancel"], _ ->
      wisp.method_not_allowed([http.Post])
    ["api", "v1", "sessions", "current", "save"], http.Post ->
      local_api.capture_save_response(
        incoming,
        local_api_context(incoming, context, now_ms),
        now_ms,
      )
    ["api", "v1", "sessions", "current", "save"], _ ->
      wisp.method_not_allowed([http.Post])
    ["api", "v1", "sessions", "current", "events"], http.Get ->
      local_api.event_window_response(
        incoming,
        local_api_context(incoming, context, now_ms),
        now_ms,
      )
    ["api", "v1", "sessions", "current", "events"], _ ->
      wisp.method_not_allowed([http.Get])
    ["api", "v1", "targets", "current", "mfas"], http.Get ->
      local_api.mfa_search_response(
        incoming,
        local_api_context(incoming, context, now_ms),
        now_ms,
      )
    ["api", "v1", "targets", "current", "mfas"], _ ->
      wisp.method_not_allowed([http.Get])
    ["api", "v1", "sessions", "current", "annotations"], http.Get ->
      team_auth_api.list_annotations(
        incoming,
        team_auth_context(context),
        now_ms,
      )
    ["api", "v1", "sessions", "current", "annotations"], http.Post ->
      team_auth_api.create_annotation(
        incoming,
        team_auth_context(context),
        now_ms,
      )
    ["api", "v1", "sessions", "current", "annotations"], _ ->
      wisp.method_not_allowed([http.Get, http.Post])
    ["api", "v1", "audit"], http.Get ->
      team_traces_api.audit_response(
        incoming,
        team_traces_context(context),
        now_ms,
      )
    ["api", "v1", "audit"], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "raw-captures", "authorize"], http.Post ->
      team_auth_api.raw_capture_authorization_response(
        incoming,
        team_auth_context(context),
        now_ms,
      )
    ["api", "v1", "raw-captures", "authorize"], _ ->
      wisp.method_not_allowed([http.Post])
    ["api", "v1", "traces"], http.Get ->
      team_traces_api.traces_response(
        incoming,
        team_traces_context(context),
        now_ms,
      )
    ["api", "v1", "traces"], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "traces", trace_id], http.Get ->
      team_traces_api.trace_detail_response(
        incoming,
        team_traces_context(context),
        trace_id,
        now_ms,
      )
    ["api", "v1", "traces", _], _ -> wisp.method_not_allowed([http.Get])
    ["api", "v1", "traces", trace_id, "events"], http.Get ->
      team_traces_api.trace_events_response(
        incoming,
        team_traces_context(context),
        trace_id,
        now_ms,
      )
    ["api", "v1", "traces", _, "events"], _ ->
      wisp.method_not_allowed([http.Get])
    ["api", "v1", "traces", trace_id, "hold"], http.Post
    | ["api", "v1", "traces", trace_id, "hold"], http.Delete
    ->
      team_traces_api.trace_hold_response(
        incoming,
        team_traces_context(context),
        trace_id,
        now_ms,
      )
    ["api", "v1", "traces", _, "hold"], _ ->
      wisp.method_not_allowed([http.Post, http.Delete])
    ["api", "v1", "relays", _, "frames"], _ ->
      wisp.json_response("{\"error\":\"endpoint_removed\"}", 410)
    ["api", "relay", "v1", "enroll"], http.Post ->
      team_auth_api.relay_enrollment_response(
        incoming,
        team_auth_context(context),
        now_ms,
      )
    ["api", "relay", "v1", "enroll"], _ -> wisp.method_not_allowed([http.Post])
    ["auth", "oidc", "start"], http.Get ->
      team_auth_api.oidc_start(team_auth_context(context), now_ms)
    ["auth", "oidc", "start"], _ -> wisp.method_not_allowed([http.Get])
    ["auth", "oidc", "callback"], http.Get ->
      team_auth_api.oidc_callback(incoming, team_auth_context(context), now_ms)
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

fn team_traces_context(context: Context) -> team_traces_api.Context {
  let mode = case context.mode {
    Local -> team_traces_api.Local
    Team -> team_traces_api.Team
  }
  let security = case context.team_security {
    None -> None
    Some(security) -> {
      let archive = case security.relay_archive {
        None -> None
        Some(RelayArchive(store, blob_root)) ->
          Some(team_traces_api.RelayArchive(
            store,
            blob_store.filesystem(blob_root),
          ))
        Some(RelayArchiveBackend(store, backend)) ->
          Some(team_traces_api.RelayArchive(store, backend))
      }
      Some(team_traces_api.TeamSecurity(
        sessions: security.sessions,
        audit: security.audit,
        origin: security.origin,
        relay_archive: archive,
      ))
    }
  }
  team_traces_api.Context(mode: mode, team_security: security)
}

fn team_auth_context(context: Context) -> team_auth_api.Context {
  let mode = case context.mode {
    Local -> team_auth_api.Local
    Team -> team_auth_api.Team
  }
  let enrollment = case context.relay_enrollment {
    None -> None
    Some(configuration) ->
      Some(team_auth_api.RelayEnrollment(
        store: configuration.store,
        channel_origin: configuration.channel_origin,
      ))
  }
  let security = case context.team_security {
    None -> None
    Some(security) -> {
      let provider = case security.oidc {
        None -> None
        Some(provider) ->
          Some(team_auth_api.OidcProvider(
            authorization_endpoint: provider.authorization_endpoint,
            client_id: provider.client_id,
            redirect_uri: provider.redirect_uri,
            issuer: provider.issuer,
            jwks_json: provider.jwks_json,
            attempts: provider.attempts,
            group_roles: provider.group_roles,
            project: provider.project,
            environment: provider.environment,
            exchange: provider.exchange,
          ))
      }
      let archive = case security.relay_archive {
        None -> None
        Some(RelayArchive(store, _)) | Some(RelayArchiveBackend(store, _)) ->
          Some(store)
      }
      Some(team_auth_api.TeamSecurity(
        sessions: security.sessions,
        annotations: security.annotations,
        audit: security.audit,
        origin: security.origin,
        oidc: provider,
        relay_archive: archive,
      ))
    }
  }
  team_auth_api.Context(
    mode: mode,
    relay_enrollment: enrollment,
    team_security: security,
  )
}

fn local_api_context(
  incoming: wisp.Request,
  context: Context,
  now_ms: Int,
) -> local_api.Context {
  local_api.Context(
    local_mode: context.mode == Local,
    tool_version: context.tool_version,
    archive_path: context.archive_path,
    local_capture: context.local_capture,
    authorize: fn(action) {
      authorize_action(incoming, context, now_ms, action)
    },
  )
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
