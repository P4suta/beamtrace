import beamtrace/codec
import beamtrace/types
import beamtrace_runtime/annotations
import beamtrace_runtime/api
import beamtrace_runtime/audit
import beamtrace_runtime/audit_store
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/local_auth
import beamtrace_runtime/oidc
import beamtrace_runtime/oidc_flow
import beamtrace_runtime/rbac
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_client
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/storage
import beamtrace_runtime/team_auth
import beamtrace_runtime/team_store
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import wisp/simulate

pub type TestSigner

@external(erlang, "beamtrace_id_token_test_ffi", "new_signer")
fn new_test_signer() -> TestSigner

@external(erlang, "beamtrace_id_token_test_ffi", "sign")
fn sign_test_token(
  signer: TestSigner,
  algorithm: String,
  issuer: String,
  audience: String,
  nonce: String,
  now_seconds: Int,
) -> String

@external(erlang, "beamtrace_id_token_test_ffi", "jwks")
fn test_signer_jwks(signer: TestSigner) -> String

pub fn health_is_versioned_json_with_security_headers_test() {
  let result =
    simulate.request(http.Get, "/api/v1/health")
    |> api.handle(api.test_context())

  result.status |> should.equal(200)
  simulate.read_body(result)
  |> should.equal(
    "{\"status\":\"ok\",\"api_version\":\"v1\",\"mode\":\"local\"}",
  )
  response.get_header(result, "cache-control") |> should.equal(Ok("no-store"))
  response.get_header(result, "x-content-type-options")
  |> should.equal(Ok("nosniff"))
  response.get_header(result, "content-security-policy")
  |> should.equal(Ok("default-src 'none'; frame-ancestors 'none'"))
}

pub fn capabilities_explicitly_exclude_mutating_rpc_test() {
  let body =
    simulate.request(http.Get, "/api/v1/capabilities")
    |> api.handle(api.test_context())
    |> simulate.read_body

  body |> string.contains("\"arbitrary_rpc\":false") |> should.be_true()
  body |> string.contains("\"process_kill\":false") |> should.be_true()
  body |> string.contains("\"ets_browser\":false") |> should.be_true()
}

pub fn unknown_api_version_is_not_found_test() {
  simulate.request(http.Get, "/api/v2/health")
  |> api.handle(api.test_context())
  |> fn(response) { response.status }
  |> should.equal(404)
}

pub fn health_rejects_wrong_method_test() {
  let response =
    simulate.request(http.Post, "/api/v1/health")
    |> api.handle(api.test_context())
  response.status |> should.equal(405)
}

pub fn workspace_assets_are_served_only_from_fixed_routes_test() {
  let context =
    api.Context(
      "0.1.0",
      api.Local,
      Some("../beamtrace_web/dist"),
      None,
      None,
      None,
      None,
    )
  let index =
    simulate.request(http.Get, "/")
    |> api.handle(context)
  index.status |> should.equal(200)
  simulate.read_body(index)
  |> string.contains("BeamTrace · BEAM causal workbench")
  |> should.be_true()

  simulate.request(http.Get, "/../gleam.toml")
  |> api.handle(context)
  |> fn(response) { response.status }
  |> should.equal(404)
}

pub fn bootstrap_route_redirects_once_with_strict_httponly_cookie_test() {
  let #(store, token) = local_auth.new_at(1000, 60_000)
  let context =
    api.Context("0.1.0", api.Local, None, Some(store), None, None, None)
  let response =
    simulate.request(http.Get, "/bootstrap/" <> token)
    |> api.handle_at(context, 1001)

  response.status |> should.equal(303)
  response.get_header(response, "location") |> should.equal(Ok("/"))
  let assert Ok(cookie) = response.get_header(response, "set-cookie")
  cookie |> string.contains("HttpOnly") |> should.be_true()
  cookie |> string.contains("SameSite=Strict") |> should.be_true()
  cookie |> string.contains(token) |> should.be_false()

  simulate.request(http.Get, "/bootstrap/" <> token)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(403)
  local_auth.close(store)
}

pub fn event_pages_require_authentication_and_enforce_a_bounded_limit_test() {
  let path = "build/beamtrace-api-window-test.beamtrace"
  let process =
    types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", "<0.1.0>"),
      logical: None,
      evidence: [],
    )
  let event =
    types.TraceEvent(
      id: "event-api",
      root_id: "root-api",
      node: "fixture@host",
      process: process,
      local_timestamp_ns: 10,
      kind: types.Stop("complete"),
      evidence: types.Exact,
    )
  let manifest =
    codec.Manifest(
      schema_version: 1,
      tool_version: "0.1.0",
      capture_id: "capture-api",
      nodes: ["fixture@host"],
      completeness: types.Complete,
      privacy: types.Metadata,
      checksums: [],
    )
  storage.save(path, manifest, [event]) |> should.equal(Ok(Nil))

  let #(store, token) = local_auth.new_at(1000, 60_000)
  let assert Ok(session) = local_auth.exchange(store, token, 1001)
  let context =
    api.Context("0.1.0", api.Local, None, Some(store), Some(path), None, None)
  let url = "/api/v1/sessions/current/events?start=0&limit=1"

  simulate.request(http.Get, url)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(401)

  let authorized =
    simulate.request(http.Get, url)
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  authorized.status |> should.equal(200)
  let body = simulate.read_body(authorized)
  body |> string.contains("\"total\":1") |> should.be_true()
  body |> string.contains("\"id\":\"event-api\"") |> should.be_true()

  let no_matches =
    simulate.request(
      http.Get,
      "/api/v1/sessions/current/events?start=0&limit=1&q=no-such-event",
    )
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  no_matches.status |> should.equal(200)
  simulate.read_body(no_matches)
  |> string.contains("\"total\":0")
  |> should.be_true()

  simulate.request(
    http.Get,
    "/api/v1/sessions/current/events?start=0&limit=1001",
  )
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(400)
  local_auth.close(store)
}

pub fn relay_enrollment_endpoint_consumes_code_once_without_echoing_it_test() {
  let #(store, code) = enrollment_store.new_at(1000, 100)
  let identity = relay_channel.new_identity()
  let assert Ok(enrollment_request) =
    relay_client.prepare_enrollment("https://hub.example", code, identity)
  let context =
    api.Context(
      "0.1.0",
      api.Team,
      None,
      None,
      None,
      Some(api.RelayEnrollment(store, "wss://hub.example")),
      None,
    )
  let request =
    simulate.request(http.Post, "/api/relay/v1/enroll")
    |> simulate.string_body(enrollment_request.body)
    |> request.set_header("content-type", "application/json")

  let response = api.handle_at(request, context, 1050)
  response.status |> should.equal(201)
  let body = simulate.read_body(response)
  body |> string.contains("\"relay_id\":\"relay-") |> should.be_true()
  body
  |> string.contains("\"channel_url\":\"wss://hub.example/")
  |> should.be_true()
  body |> string.contains(code) |> should.be_false()

  simulate.request(http.Post, "/api/relay/v1/enroll")
  |> simulate.string_body(enrollment_request.body)
  |> request.set_header("content-type", "application/json")
  |> api.handle_at(context, 1051)
  |> fn(response) { response.status }
  |> should.equal(409)
  enrollment_store.close(store)
}

pub fn team_relay_frames_are_authenticated_paged_and_keep_gap_evidence_test() {
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let audit_log = audit_store.new()
  let inbox = relay_inbox.new(max_frames: 2, max_bytes: 256)
  let viewer = team_session(sessions, "viewer-frames", [rbac.Viewer])
  let relay_id = "relay-aabbccddeeff001122334455"
  relay_inbox.append(
    inbox,
    relay_id,
    1,
    relay_inbox.Live,
    "{\"event\":\"one\"}",
    1000,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    inbox,
    relay_id,
    2,
    relay_inbox.Live,
    "{\"event\":\"two\"}",
    1001,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    inbox,
    relay_id,
    3,
    relay_inbox.Live,
    "{\"event\":\"three\"}",
    1002,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  let context =
    api.Context(
      "0.1.0",
      api.Team,
      None,
      None,
      None,
      None,
      Some(api.TeamSecurity(
        sessions,
        annotation_store,
        audit_log,
        "https://hub.example",
        None,
        Some(inbox),
        None,
      )),
    )
  let url = "/api/v1/relays/" <> relay_id <> "/frames?start=0&limit=2"

  simulate.request(http.Get, url)
  |> api.handle_at(context, 1003)
  |> fn(response) { response.status }
  |> should.equal(401)

  let authorized =
    simulate.request(http.Get, url)
    |> request.set_header("cookie", "beamtrace_session=" <> viewer.id)
    |> api.handle_at(context, 1003)
  authorized.status |> should.equal(200)
  let body = simulate.read_body(authorized)
  body |> string.contains("\"total\":3") |> should.be_true()
  body |> string.contains("\"kind\":\"gap\"") |> should.be_true()
  body |> string.contains("\"dropped_frames\":1") |> should.be_true()
  body |> string.contains("\\\"event\\\":\\\"two\\\"") |> should.be_true()
  body |> string.contains("event\\\":\\\"three") |> should.be_false()

  simulate.request(
    http.Get,
    "/api/v1/relays/" <> relay_id <> "/frames?start=0&limit=201",
  )
  |> request.set_header("cookie", "beamtrace_session=" <> viewer.id)
  |> api.handle_at(context, 1003)
  |> fn(response) { response.status }
  |> should.equal(400)

  relay_inbox.close(inbox)
  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
}

pub fn team_relay_frames_fall_back_to_durable_archive_after_restart_test() {
  let database = "build/beamtrace-api-relay-archive-test.sqlite3"
  let blobs = "build/beamtrace-api-relay-archive-blobs"
  let relay_id = "relay-abcdefabcdefabcdefabcdef"
  let payload = "{\"type\":\"batch\",\"mode\":\"exact\",\"event\":\"durable\"}"
  let assert Ok(initial) = team_store.open(database)
  relay_archive.persist(
    initial,
    blobs,
    relay_id,
    1,
    relay_archive.Exact,
    payload,
    4000,
  )
  |> should.be_ok
  team_store.close(initial) |> should.equal(Ok(Nil))

  let assert Ok(reopened) = team_store.open(database)
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let audit_log = audit_store.new()
  let empty_inbox = relay_inbox.new(max_frames: 2, max_bytes: 256)
  let viewer = team_session(sessions, "viewer-durable", [rbac.Viewer])
  let context =
    api.Context(
      "0.1.0",
      api.Team,
      None,
      None,
      None,
      None,
      Some(api.TeamSecurity(
        sessions,
        annotation_store,
        audit_log,
        "https://hub.example",
        None,
        Some(empty_inbox),
        Some(api.RelayArchive(reopened, blobs)),
      )),
    )

  let response =
    simulate.request(
      http.Get,
      "/api/v1/relays/" <> relay_id <> "/frames?start=0&limit=10",
    )
    |> request.set_header("cookie", "beamtrace_session=" <> viewer.id)
    |> api.handle_at(context, 4001)
  response.status |> should.equal(200)
  let body = simulate.read_body(response)
  body |> string.contains("\"total\":1") |> should.be_true()
  body |> string.contains("durable") |> should.be_true()

  relay_inbox.close(empty_inbox)
  team_store.close(reopened) |> should.equal(Ok(Nil))
  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
}

pub fn team_annotations_enforce_session_rbac_origin_and_csrf_test() {
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let audit_log = audit_store.new()
  let viewer = team_session(sessions, "viewer-1", [rbac.Viewer])
  let investigator =
    team_session(sessions, "investigator-1", [rbac.Investigator])
  let context =
    api.Context(
      "0.1.0",
      api.Team,
      None,
      None,
      None,
      None,
      Some(api.TeamSecurity(
        sessions,
        annotation_store,
        audit_log,
        "https://hub.example",
        None,
        None,
        None,
      )),
    )
  let body = "{\"event_id\":\"event-1\",\"text\":\"check restart\"}"

  annotation_request(viewer, body, "https://hub.example", viewer.csrf_token)
  |> api.handle_at(context, 1001)
  |> fn(response) { response.status }
  |> should.equal(403)

  annotation_request(
    investigator,
    body,
    "https://evil.example",
    investigator.csrf_token,
  )
  |> api.handle_at(context, 1001)
  |> fn(response) { response.status }
  |> should.equal(403)

  annotation_request(
    investigator,
    body,
    "https://hub.example",
    "attacker-token",
  )
  |> api.handle_at(context, 1001)
  |> fn(response) { response.status }
  |> should.equal(403)

  let created =
    annotation_request(
      investigator,
      body,
      "https://hub.example",
      investigator.csrf_token,
    )
    |> api.handle_at(context, 1001)
  created.status |> should.equal(201)
  simulate.read_body(created)
  |> string.contains("\"author\":\"investigator-1\"")
  |> should.be_true()

  let listed =
    simulate.request(http.Get, "/api/v1/sessions/current/annotations")
    |> request.set_header("cookie", "beamtrace_session=" <> viewer.id)
    |> api.handle_at(context, 1002)
  listed.status |> should.equal(200)
  simulate.read_body(listed)
  |> string.contains("check restart")
  |> should.be_true()

  let recorded = audit_store.snapshot(audit_log)
  audit.verify(recorded) |> should.equal(Ok(Nil))
  let assert [first, second, third, fourth] = recorded.entries
  [first.outcome, second.outcome, third.outcome, fourth.outcome]
  |> should.equal(["denied_rbac", "denied_csrf", "denied_csrf", "allowed"])
  recorded.entries
  |> list.all(fn(entry) { entry.action == "annotation.create" })
  |> should.be_true()

  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
}

pub fn team_audit_api_is_admin_only_and_bounded_test() {
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let audit_log = audit_store.new()
  audit_store.append(
    audit_log,
    7000,
    "relay-aabb",
    "relay.enroll",
    "relay-aabb",
    "allowed",
  )
  let viewer = team_session(sessions, "audit-viewer", [rbac.Viewer])
  let admin = team_session(sessions, "audit-admin", [rbac.Admin])
  let context =
    api.Context(
      "0.1.0",
      api.Team,
      None,
      None,
      None,
      None,
      Some(api.TeamSecurity(
        sessions,
        annotation_store,
        audit_log,
        "https://hub.example",
        None,
        None,
        None,
      )),
    )
  let url = "/api/v1/audit?start=0&limit=1"

  simulate.request(http.Get, url)
  |> api.handle_at(context, 7001)
  |> fn(response) { response.status }
  |> should.equal(401)
  simulate.request(http.Get, url)
  |> request.set_header("cookie", "beamtrace_session=" <> viewer.id)
  |> api.handle_at(context, 7001)
  |> fn(response) { response.status }
  |> should.equal(403)

  let authorized =
    simulate.request(http.Get, url)
    |> request.set_header("cookie", "beamtrace_session=" <> admin.id)
    |> api.handle_at(context, 7001)
  authorized.status |> should.equal(200)
  let body = simulate.read_body(authorized)
  body |> string.contains("\"total\":1") |> should.be_true()
  body |> string.contains("\"action\":\"relay.enroll\"") |> should.be_true()
  body |> string.contains("\"previous_hash\":") |> should.be_true()

  simulate.request(http.Get, "/api/v1/audit?start=0&limit=201")
  |> request.set_header("cookie", "beamtrace_session=" <> admin.id)
  |> api.handle_at(context, 7001)
  |> fn(response) { response.status }
  |> should.equal(400)

  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
}

pub fn oidc_http_flow_uses_pkce_and_exchanges_callback_once_test() {
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let audit_log = audit_store.new()
  let attempts = oidc_flow.new()
  let signer = new_test_signer()
  let provider =
    api.OidcProvider(
      authorization_endpoint: "https://id.example/authorize",
      client_id: "beamtrace-client",
      redirect_uri: "https://hub.example/auth/oidc/callback",
      issuer: "https://id.example",
      jwks_json: test_signer_jwks(signer),
      attempts: attempts,
      group_roles: [#("beamtrace-investigators", rbac.Viewer)],
      project: "shop",
      environment: "prod",
      exchange: fn(code, verifier, redirect_uri) {
        case
          string.length(verifier) >= 43,
          redirect_uri == "https://hub.example/auth/oidc/callback"
        {
          True, True -> {
            Ok(sign_test_token(
              signer,
              "RS256",
              "https://id.example",
              "beamtrace-client",
              code,
              1,
            ))
          }
          _, _ -> Error("invalid_exchange")
        }
      },
    )
  let context =
    api.Context(
      "0.1.0",
      api.Team,
      None,
      None,
      None,
      None,
      Some(api.TeamSecurity(
        sessions,
        annotation_store,
        audit_log,
        "https://hub.example",
        Some(provider),
        None,
        None,
      )),
    )

  let started =
    simulate.request(http.Get, "/auth/oidc/start")
    |> api.handle_at(context, 1000)
  started.status |> should.equal(303)
  let assert Ok(location) = response.get_header(started, "location")
  location
  |> string.starts_with("https://id.example/authorize?")
  |> should.be_true()
  location
  |> string.contains("code_challenge_method=S256")
  |> should.be_true()
  location |> string.contains("code_verifier") |> should.be_false()
  let assert Ok(state) = url_parameter(location, "state")
  let assert Ok(nonce) = url_parameter(location, "nonce")

  let callback =
    simulate.request(
      http.Get,
      "/auth/oidc/callback?state=" <> state <> "&code=" <> nonce,
    )
    |> api.handle_at(context, 1001)
  callback.status |> should.equal(303)
  response.get_header(callback, "location") |> should.equal(Ok("/"))
  let cookies =
    callback.headers
    |> list.filter(fn(header) { header.0 == "set-cookie" })
    |> list.map(fn(header) { header.1 })
    |> string.join("\n")
  cookies |> string.contains("beamtrace_session=") |> should.be_true()
  cookies |> string.contains("beamtrace_csrf=") |> should.be_true()
  cookies |> string.contains("HttpOnly") |> should.be_true()
  cookies |> string.contains("Secure") |> should.be_true()
  cookies |> string.contains(state) |> should.be_false()
  cookies |> string.contains(nonce) |> should.be_false()

  let assert Ok(session_id) =
    response_cookie(callback.headers, "beamtrace_session")
  let assert Ok(session) = team_auth.authorize_at(sessions, session_id, 1002)
  session.subject |> should.equal("user-1")
  session.roles |> should.equal([rbac.Viewer])

  simulate.request(http.Get, "/api/v1/sessions/current/annotations")
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(200)
  annotation_request(
    session,
    "{\"event_id\":\"event-oidc\",\"text\":\"must not write\"}",
    "https://hub.example",
    session.csrf_token,
  )
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(403)

  simulate.request(
    http.Get,
    "/auth/oidc/callback?state=" <> state <> "&code=" <> nonce,
  )
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(409)

  let log = audit_store.snapshot(audit_log)
  audit.verify(log) |> should.equal(Ok(Nil))
  let assert [login, denied_annotation] = log.entries
  login.action |> should.equal("session.login")
  login.actor |> should.equal("user-1")
  login.outcome |> should.equal("allowed")
  denied_annotation.action |> should.equal("annotation.create")
  denied_annotation.outcome |> should.equal("denied_rbac")

  oidc_flow.close(attempts)
  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
}

pub fn oidc_nonce_mismatch_is_rejected_and_state_cannot_be_replayed_test() {
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let audit_log = audit_store.new()
  let attempts = oidc_flow.new()
  let signer = new_test_signer()
  let provider =
    api.OidcProvider(
      "https://id.example/authorize",
      "client",
      "https://hub.example/auth/oidc/callback",
      "https://id.example",
      test_signer_jwks(signer),
      attempts,
      [#("beamtrace-investigators", rbac.Viewer)],
      "shop",
      "prod",
      fn(code, _verifier, _redirect_uri) {
        Ok(sign_test_token(
          signer,
          "RS256",
          "https://id.example",
          "client",
          code,
          1,
        ))
      },
    )
  let context =
    api.Context(
      "0.1.0",
      api.Team,
      None,
      None,
      None,
      None,
      Some(api.TeamSecurity(
        sessions,
        annotation_store,
        audit_log,
        "https://hub.example",
        Some(provider),
        None,
        None,
      )),
    )
  let started =
    simulate.request(http.Get, "/auth/oidc/start")
    |> api.handle_at(context, 1000)
  let assert Ok(location) = response.get_header(started, "location")
  let assert Ok(state) = url_parameter(location, "state")

  simulate.request(
    http.Get,
    "/auth/oidc/callback?state=" <> state <> "&code=wrong-nonce",
  )
  |> api.handle_at(context, 1001)
  |> fn(response) { response.status }
  |> should.equal(401)
  simulate.request(
    http.Get,
    "/auth/oidc/callback?state=" <> state <> "&code=wrong-nonce",
  )
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(409)

  oidc_flow.close(attempts)
  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
}

pub fn production_oidc_provider_rejects_an_insecure_token_endpoint_test() {
  let attempts = oidc_flow.new()
  let provider =
    api.production_oidc_provider(
      authorization_endpoint: "https://id.example/authorize",
      token_endpoint: "http://id.example/token",
      client_id: "client",
      redirect_uri: "https://hub.example/auth/oidc/callback",
      issuer: "https://id.example",
      jwks_json: "{\"keys\":[]}",
      attempts: attempts,
      group_roles: [],
      project: "shop",
      environment: "prod",
    )

  provider.exchange(
    "code",
    string.repeat("v", 43),
    "https://hub.example/auth/oidc/callback",
  )
  |> should.equal(Error("token_exchange_failed"))
  oidc_flow.close(attempts)
}

fn annotation_request(
  session: team_auth.Session,
  body: String,
  origin: String,
  csrf_token: String,
) {
  simulate.request(http.Post, "/api/v1/sessions/current/annotations")
  |> simulate.string_body(body)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("origin", origin)
  |> request.set_header("x-beamtrace-csrf", csrf_token)
  |> request.set_header(
    "cookie",
    "beamtrace_session="
      <> session.id
      <> "; beamtrace_csrf="
      <> session.csrf_token,
  )
}

fn team_session(
  store: team_auth.Store,
  subject: String,
  roles: List(rbac.Role),
) -> team_auth.Session {
  let verifier = "verifier-" <> subject
  let attempt =
    oidc.new(
      "state-" <> subject,
      "nonce-" <> subject,
      oidc.pkce_s256(verifier),
      "https://hub.example/callback",
      2000,
    )
  let assert Ok(validated) =
    oidc.validate(
      attempt,
      oidc.state(attempt),
      oidc.nonce(attempt),
      verifier,
      oidc.redirect_uri(attempt),
      1000,
      oidc.pkce_s256,
    )
  let assert Ok(session) =
    team_auth.issue_from_oidc(
      store,
      validated,
      subject,
      roles,
      "shop",
      "prod",
      1000,
      60_000,
    )
  session
}

fn url_parameter(url: String, name: String) -> Result(String, Nil) {
  url
  |> string.split("?")
  |> list.drop(1)
  |> string.join("?")
  |> string.split("&")
  |> list.find_map(fn(part) {
    case string.split(part, "=") {
      [key, value] if key == name -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

fn response_cookie(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  let prefix = name <> "="
  list.find_map(headers, fn(header) {
    case header.0 == "set-cookie", string.starts_with(header.1, prefix) {
      True, True ->
        case string.split(header.1, ";") {
          [pair, ..] -> Ok(string.drop_start(pair, string.length(prefix)))
          _ -> Error(Nil)
        }
      _, _ -> Error(Nil)
    }
  })
}
