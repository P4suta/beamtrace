import beamtrace/codec
import beamtrace/types
import beamtrace_runtime/annotations
import beamtrace_runtime/api
import beamtrace_runtime/audit
import beamtrace_runtime/audit_store
import beamtrace_runtime/blob_store
import beamtrace_runtime/capture
import beamtrace_runtime/capture_session
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/live
import beamtrace_runtime/local_auth
import beamtrace_runtime/oidc
import beamtrace_runtime/oidc_flow
import beamtrace_runtime/raw_grant
import beamtrace_runtime/rbac
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_client
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/storage
import beamtrace_runtime/team_auth
import beamtrace_runtime/team_store
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import wisp/simulate

pub type TestSigner

type RawGrantResponse {
  RawGrantResponse(grant: String, expires_at_ms: Int)
}

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

@external(erlang, "beamtrace_team_store_migration_test_ffi", "fresh_store_path")
fn fresh_store_path() -> String

@external(erlang, "beamtrace_team_store_migration_test_ffi", "fresh_data_dir")
fn fresh_data_dir() -> String

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
    api.Context("0.1.0", api.Local, None, Some(store), None, None, None, None)
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
    api.Context(
      "0.1.0",
      api.Local,
      None,
      Some(store),
      Some(path),
      None,
      None,
      None,
    )
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

pub fn local_capture_api_arms_pages_and_saves_a_real_session_test() {
  let captured =
    capture.CaptureResult(
      events: [session_event("captured-root")],
      completeness: types.Complete,
    )
  let capture_store =
    capture_session.new_with_backends_for_nodes(
      ["app@host"],
      fn(spec) {
        case spec.max_roots == 3, spec.preset == types.GenServer {
          True, True -> Ok(captured)
          _, _ -> Error("capture_spec_not_forwarded")
        }
      },
      fn(node, _query, _limit) {
        Ok([capture.MfaCandidate(node, "shop", "checkout", 1)])
      },
    )
  let #(auth, token) = local_auth.new_at(1000, 60_000)
  let assert Ok(session) = local_auth.exchange(auth, token, 1001)
  let context =
    api.Context(
      tool_version: "0.1.0",
      mode: api.Local,
      static_root: None,
      local_auth: Some(auth),
      archive_path: None,
      relay_enrollment: None,
      team_security: None,
      local_capture: Some(capture_store),
    )
  let body =
    "{\"trigger\":\"shop:checkout/1\",\"where\":null,"
    <> "\"capture_window_ms\":1000,\"max_events\":1000,"
    <> "\"max_bytes\":1000000,\"max_agent_mailbox\":100,"
    <> "\"max_roots\":3,\"preset\":\"gen-server\"}"

  simulate.request(http.Get, "/api/v1/targets/current/mfas?q=check&limit=20")
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(401)

  let candidates =
    simulate.request(http.Get, "/api/v1/targets/current/mfas?q=check&limit=20")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  candidates.status |> should.equal(200)
  simulate.read_body(candidates)
  |> string.contains("\"mfa\":\"shop:checkout/1\"")
  |> should.be_true()

  simulate.request(http.Post, "/api/v1/sessions/current/arm")
  |> simulate.string_body(body)
  |> request.set_header("content-type", "application/json")
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(401)

  let invalid_preset =
    "{\"trigger\":\"shop:checkout/1\",\"where\":null,"
    <> "\"capture_window_ms\":1000,\"max_events\":1000,"
    <> "\"max_bytes\":1000000,\"max_agent_mailbox\":100,"
    <> "\"max_roots\":3,\"preset\":\"magic\"}"
  simulate.request(http.Post, "/api/v1/sessions/current/arm")
  |> simulate.string_body(invalid_preset)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(400)

  let invalid_roots =
    "{\"trigger\":\"shop:checkout/1\",\"where\":null,"
    <> "\"capture_window_ms\":1000,\"max_events\":1000,"
    <> "\"max_bytes\":1000000,\"max_agent_mailbox\":100,"
    <> "\"max_roots\":0,\"preset\":\"generic\"}"
  simulate.request(http.Post, "/api/v1/sessions/current/arm")
  |> simulate.string_body(invalid_roots)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(400)

  let armed =
    simulate.request(http.Post, "/api/v1/sessions/current/arm")
    |> simulate.string_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  armed.status |> should.equal(202)
  simulate.read_body(armed)
  |> string.contains("\"status\":\"armed\"")
  |> should.be_true()
  capture_session.await(capture_store, 1000) |> should.equal(Ok(captured))

  let status =
    simulate.request(http.Get, "/api/v1/sessions/current")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1003)
  status.status |> should.equal(200)
  simulate.read_body(status)
  |> string.contains("\"status\":\"ready\"")
  |> should.be_true()

  let events =
    simulate.request(
      http.Get,
      "/api/v1/sessions/current/events?start=0&limit=10",
    )
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1003)
  events.status |> should.equal(200)
  simulate.read_body(events)
  |> string.contains("\"id\":\"captured-root\"")
  |> should.be_true()

  let path = "build/beamtrace-api-session-save.beamtrace"
  let saved =
    simulate.request(http.Post, "/api/v1/sessions/current/save")
    |> simulate.string_body("{\"path\":\"" <> path <> "\"}")
    |> request.set_header("content-type", "application/json")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1004)
  saved.status |> should.equal(201)
  storage.load(path) |> should.be_ok

  capture_session.close(capture_store)
  local_auth.close(auth)
}

pub fn occupied_tracer_status_offers_live_without_claiming_exact_capture_test() {
  let capture_store =
    capture_session.new_with_backend(fn(_spec) {
      Error("system_tracer_occupied")
    })
  let #(auth, token) = local_auth.new_at(1000, 60_000)
  let assert Ok(session) = local_auth.exchange(auth, token, 1001)
  let context =
    api.Context(
      "0.1.0",
      api.Local,
      None,
      Some(auth),
      None,
      None,
      None,
      Some(capture_store),
    )
  let body =
    "{\"trigger\":\"shop:checkout/1\",\"where\":null,"
    <> "\"capture_window_ms\":1000,\"max_events\":1000,"
    <> "\"max_bytes\":1000000,\"max_agent_mailbox\":100,"
    <> "\"max_roots\":1,\"preset\":\"generic\"}"

  simulate.request(http.Post, "/api/v1/sessions/current/arm")
  |> simulate.string_body(body)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(202)
  capture_session.await(capture_store, 1000)
  |> should.equal(
    Error(capture_session.CaptureFailed("system_tracer_occupied")),
  )

  let response =
    simulate.request(http.Get, "/api/v1/sessions/current")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1003)
  response.status |> should.equal(200)
  let status = simulate.read_body(response)
  status |> string.contains("\"exact_capture\":false") |> should.be_true()
  status
  |> string.contains("\"fallback\":\"live_sampling\"")
  |> should.be_true()
  capture_session.close(capture_store)
  local_auth.close(auth)
}

pub fn live_api_is_authenticated_shared_bounded_and_explains_inferences_test() {
  let capture_store =
    capture_session.new_with_live_backend_for_nodes(
      ["app@host"],
      fn(_spec) { Error("capture_unused") },
      fn(_node, offset, _limit) {
        let sample = case offset {
          0 -> live_sample(1, 1000, 10)
          _ -> live_sample(50, 10_000, 1000)
        }
        Ok(#([sample], offset + 1))
      },
    )
  let #(auth, token) = local_auth.new_at(1000, 60_000)
  let assert Ok(session) = local_auth.exchange(auth, token, 1001)
  let context =
    api.Context(
      "0.1.0",
      api.Local,
      None,
      Some(auth),
      None,
      None,
      None,
      Some(capture_store),
    )

  simulate.request(http.Get, "/api/v1/live?limit=20")
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(401)

  simulate.request(http.Get, "/api/v1/live?limit=1001")
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(400)

  let first =
    simulate.request(http.Get, "/api/v1/live?limit=20")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  first.status |> should.equal(200)
  let first_body = simulate.read_body(first)
  first_body |> string.contains("\"generation\":1") |> should.be_true()
  first_body
  |> string.contains("\"label\":\"orders worker\"")
  |> should.be_true()
  first_body |> string.contains("\"mailbox_len\":1") |> should.be_true()
  first_body
  |> string.contains("\"links\":[\"<0.7.0>\"]")
  |> should.be_true()
  first_body |> string.contains("\"findings\":[]") |> should.be_true()

  let shared =
    simulate.request(http.Get, "/api/v1/live?limit=20")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1200)
    |> simulate.read_body
  shared |> string.contains("\"generation\":1") |> should.be_true()

  let rotated =
    simulate.request(http.Get, "/api/v1/live?limit=20")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1603)
    |> simulate.read_body
  rotated |> string.contains("\"generation\":2") |> should.be_true()
  rotated
  |> string.contains("\"kind\":\"mailbox_growth\"")
  |> should.be_true()
  rotated
  |> string.contains("\"status\":\"inferred\"")
  |> should.be_true()
  rotated |> string.contains("\"supervision\"") |> should.be_true()
  rotated
  |> string.contains("\"reason\":\"proc_lib ancestor metadata\"")
  |> should.be_true()

  capture_session.close(capture_store)
  local_auth.close(auth)
}

pub fn compare_api_loads_multiple_local_traces_and_returns_visual_alignment_data_test() {
  let left = "build/api-compare-left.beamtrace"
  let right = "build/api-compare-right.beamtrace"
  let manifest =
    codec.Manifest(
      1,
      "0.1.0",
      "api-compare",
      ["app@host"],
      types.Complete,
      types.Metadata,
      [],
    )
  storage.save(left, manifest, [session_event("left-root")])
  |> should.equal(Ok(Nil))
  storage.save(right, manifest, [
    session_event("right-root"),
    types.TraceEvent(
      ..session_event("right-extra"),
      kind: types.Stop("extra branch"),
      local_timestamp_ns: 20,
    ),
  ])
  |> should.equal(Ok(Nil))

  let #(auth, token) = local_auth.new_at(1000, 60_000)
  let assert Ok(session) = local_auth.exchange(auth, token, 1001)
  let context =
    api.Context("0.1.0", api.Local, None, Some(auth), None, None, None, None)
  let body = "{\"paths\":[\"" <> left <> "\",\"" <> right <> "\"]}"

  simulate.request(http.Post, "/api/v1/compare")
  |> simulate.string_body(body)
  |> request.set_header("content-type", "application/json")
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(401)

  simulate.request(http.Post, "/api/v1/compare")
  |> simulate.string_body("{\"paths\":[\"only.beamtrace\"]}")
  |> request.set_header("content-type", "application/json")
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(400)

  let compared =
    simulate.request(http.Post, "/api/v1/compare")
    |> simulate.string_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  compared.status |> should.equal(200)
  let result = simulate.read_body(compared)
  result |> string.contains("\"run_count\":2") |> should.be_true()
  result |> string.contains("\"added\":1") |> should.be_true()
  result |> string.contains("\"status\":\"added\"") |> should.be_true()
  result |> string.contains("\"p50_ns\"") |> should.be_true()
  result |> string.contains("\"occurrence_rate\"") |> should.be_true()

  local_auth.close(auth)
}

fn live_sample(
  mailbox_len: Int,
  memory_bytes: Int,
  reductions: Int,
) -> live.ProcessSample {
  live.ProcessSample(
    node: "app@host",
    pid: "<0.42.0>",
    label: "orders worker",
    registered_name: "orders",
    process_label: "orders worker",
    initial_call: "orders_worker:init/1",
    mailbox_len: mailbox_len,
    memory_bytes: memory_bytes,
    reductions: reductions,
    heap_words: 100,
    total_heap_words: 200,
    link_count: 1,
    status: "waiting",
    current_function: "gen_server:loop/7",
    links: ["<0.7.0>"],
    ancestors: ["orders_sup"],
  )
}

fn session_event(id: String) -> types.TraceEvent {
  let physical = types.ProcessRef("app@host", "<0.1.0>")
  types.TraceEvent(
    id: id,
    root_id: id,
    node: "app@host",
    process: types.ProcessIdentity(physical, None, []),
    local_timestamp_ns: 1,
    kind: types.Root(types.Mfa("shop", "checkout", 1), []),
    evidence: types.Exact,
  )
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
    relay_inbox.Metadata,
    "{\"event\":\"one\"}",
    1000,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    inbox,
    relay_id,
    2,
    relay_inbox.Live,
    relay_inbox.Metadata,
    "{\"event\":\"two\"}",
    1001,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    inbox,
    relay_id,
    3,
    relay_inbox.Live,
    relay_inbox.Metadata,
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
      None,
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

pub fn raw_and_unknown_inbox_frames_require_combined_role_and_audit_test() {
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let audit_log = audit_store.new()
  let inbox = relay_inbox.new(max_frames: 8, max_bytes: 4096)
  let relay_id = "relay-001100110011001100110011"
  let raw_payload = "{\"private\":\"raw-secret\"}"
  relay_inbox.append(
    inbox,
    relay_id,
    1,
    relay_inbox.Exact,
    relay_inbox.Metadata,
    "{\"safe\":true}",
    3000,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    inbox,
    relay_id,
    2,
    relay_inbox.Exact,
    relay_inbox.Raw,
    raw_payload,
    3001,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    inbox,
    relay_id,
    3,
    relay_inbox.Exact,
    relay_inbox.Unknown,
    "{\"private\":\"legacy-secret\"}",
    3002,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  let viewer = team_session(sessions, "raw-read-viewer", [rbac.Viewer])
  let investigator =
    team_session(sessions, "raw-read-investigator", [rbac.Investigator])
  let raw_only =
    team_session(sessions, "raw-read-role-only", [rbac.RawCaptureRole])
  let combined =
    team_session(sessions, "raw-read-combined", [
      rbac.Investigator,
      rbac.RawCaptureRole,
    ])
  let admin = team_session(sessions, "raw-read-admin", [rbac.Admin])
  let context =
    api.Context(
      "0.1.1",
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
      None,
    )
  let metadata_url = "/api/v1/relays/" <> relay_id <> "/frames?start=0&limit=1"
  let mixed_url = "/api/v1/relays/" <> relay_id <> "/frames?start=0&limit=10"

  [viewer, investigator, raw_only, combined, admin]
  |> list.each(fn(session) {
    let response =
      simulate.request(http.Get, metadata_url)
      |> request.set_header("cookie", "beamtrace_session=" <> session.id)
      |> api.handle_at(context, 3009)
    response.status |> should.equal(200)
    simulate.read_body(response)
    |> string.contains("\\\"safe\\\":true")
    |> should.be_true()
  })

  [viewer, investigator, raw_only]
  |> list.each(fn(session) {
    let denied =
      simulate.request(http.Get, mixed_url)
      |> request.set_header("cookie", "beamtrace_session=" <> session.id)
      |> api.handle_at(context, 3010)
    denied.status |> should.equal(403)
    let body = simulate.read_body(denied)
    body |> string.contains("raw-secret") |> should.be_false()
    body |> string.contains("safe") |> should.be_false()
  })

  [combined, admin]
  |> list.each(fn(session) {
    let response =
      simulate.request(http.Get, mixed_url)
      |> request.set_header("cookie", "beamtrace_session=" <> session.id)
      |> api.handle_at(context, 3011)
    response.status |> should.equal(200)
    let body = simulate.read_body(response)
    body |> string.contains("raw-secret") |> should.be_true()
    body |> string.contains("legacy-secret") |> should.be_true()
    body |> string.contains("\"privacy\":\"unknown\"") |> should.be_true()
  })

  let reads = audit_store.snapshot(audit_log)
  audit.verify(reads) |> should.equal(Ok(Nil))
  reads.entries |> list.length |> should.equal(5)
  reads.entries
  |> list.map(fn(entry) { entry.outcome })
  |> should.equal([
    "denied_rbac",
    "denied_rbac",
    "denied_rbac",
    "allowed",
    "allowed",
  ])
  reads.entries
  |> list.all(fn(entry) { entry.action == "raw_trace.read" })
  |> should.be_true()

  relay_inbox.close(inbox)
  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
}

pub fn archive_privacy_is_checked_before_filesystem_or_s3_blob_fetch_test() {
  let relay_id = "relay-abcdef000000abcdef000000"
  let frame =
    team_store.RelayFrameIndex(
      relay_id: relay_id,
      sequence: 1,
      received_at_ms: 5000,
      mode: "exact",
      privacy: "raw",
      blob_key: "relays/relay-abcdef000000abcdef000000/frames/missing.json",
      event_count: 1,
      bytes: 10,
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    )
  let assert Ok(metadata) = team_store.open(":memory:")
  team_store.put_relay_frame(metadata, frame) |> should.equal(Ok(Nil))
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let audit_log = audit_store.new()
  let viewer = team_session(sessions, "prefetch-viewer", [rbac.Viewer])
  let assert Ok(s3) =
    blob_store.s3(
      endpoint: "https://127.0.0.1:1",
      bucket: "beamtrace-test",
      region: "ap-northeast-1",
      prefix: "pre-fetch",
    )
  let backends = [
    blob_store.filesystem("build/missing-hotfix-blobs"),
    s3,
  ]

  backends
  |> list.each(fn(backend) {
    let context =
      api.Context(
        "0.1.1",
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
          Some(api.RelayArchiveBackend(metadata, backend)),
        )),
        None,
      )
    simulate.request(
      http.Get,
      "/api/v1/relays/" <> relay_id <> "/frames?start=0&limit=10",
    )
    |> request.set_header("cookie", "beamtrace_session=" <> viewer.id)
    |> api.handle_at(context, 5001)
    |> fn(response) { response.status }
    |> should.equal(403)
  })

  let reads = audit_store.snapshot(audit_log)
  reads.entries
  |> list.map(fn(entry) { entry.outcome })
  |> should.equal(["denied_rbac", "denied_rbac"])
  audit.verify(reads) |> should.equal(Ok(Nil))

  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
  team_store.close(metadata) |> should.equal(Ok(Nil))
}

pub fn team_relay_frames_fall_back_to_durable_archive_after_restart_test() {
  let database = fresh_store_path()
  let blobs = fresh_data_dir()
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
  let assert Ok(audit_log) = audit_store.persistent(reopened)
  let empty_inbox = relay_inbox.new(max_frames: 2, max_bytes: 256)
  let viewer = team_session(sessions, "viewer-durable", [rbac.Viewer])
  let authorized =
    team_session(sessions, "raw-durable", [
      rbac.Investigator,
      rbac.RawCaptureRole,
    ])
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
      None,
    )

  let denied =
    simulate.request(
      http.Get,
      "/api/v1/relays/" <> relay_id <> "/frames?start=0&limit=10",
    )
    |> request.set_header("cookie", "beamtrace_session=" <> viewer.id)
    |> api.handle_at(context, 4001)
  denied.status |> should.equal(403)
  simulate.read_body(denied) |> string.contains("durable") |> should.be_false()

  let response =
    simulate.request(
      http.Get,
      "/api/v1/relays/" <> relay_id <> "/frames?start=0&limit=10",
    )
    |> request.set_header("cookie", "beamtrace_session=" <> authorized.id)
    |> api.handle_at(context, 4001)
  response.status |> should.equal(200)
  let body = simulate.read_body(response)
  body |> string.contains("\"total\":1") |> should.be_true()
  body |> string.contains("durable") |> should.be_true()

  let reads = audit_store.snapshot(audit_log)
  audit.verify(reads) |> should.equal(Ok(Nil))
  let assert [denied_read, allowed_read] = reads.entries
  [denied_read.action, allowed_read.action]
  |> should.equal(["raw_trace.read", "raw_trace.read"])
  [denied_read.outcome, allowed_read.outcome]
  |> should.equal(["denied_rbac", "allowed"])

  audit_store.close(audit_log)
  relay_inbox.close(empty_inbox)
  team_store.close(reopened) |> should.equal(Ok(Nil))

  let assert Ok(audit_database) = team_store.open(database)
  team_store.audit_log(audit_database) |> should.equal(Ok(reads))
  team_store.close(audit_database) |> should.equal(Ok(Nil))
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
      None,
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

pub fn team_raw_capture_authorization_is_rbac_csrf_bounded_and_audited_test() {
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let assert Ok(metadata) = team_store.open(":memory:")
  let enrolled_identity = relay_channel.new_identity()
  team_store.put_relay_identity(
    metadata,
    team_store.RelayIdentity(
      "relay-11223344556677889900aabb",
      "Ed25519",
      enrolled_identity.public_key,
      9000,
    ),
  )
  |> should.equal(Ok(Nil))
  let assert Ok(audit_log) = audit_store.persistent(metadata)
  let investigator = team_session(sessions, "raw-no-role", [rbac.Investigator])
  let raw_investigator =
    team_session(sessions, "raw-allowed", [
      rbac.Investigator,
      rbac.RawCaptureRole,
    ])
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
        Some(api.RelayArchive(metadata, "build/raw-api-blobs")),
      )),
      None,
    )
  let body =
    "{\"relay_id\":\"relay-11223344556677889900aabb\","
    <> "\"duration_ms\":5000,\"max_events\":10,\"max_bytes\":4096,"
    <> "\"redact_keys\":[\"password\",\"token\"],"
    <> "\"max_depth\":4,\"max_binary_bytes\":64}"

  raw_grant_request(investigator, body, investigator.csrf_token)
  |> api.handle_at(context, 10_000)
  |> fn(response) { response.status }
  |> should.equal(403)
  raw_grant_request(raw_investigator, body, "wrong-csrf")
  |> api.handle_at(context, 10_000)
  |> fn(response) { response.status }
  |> should.equal(403)
  let unknown_relay_body =
    string.replace(
      body,
      "relay-11223344556677889900aabb",
      "relay-ffffffffffffffffffffffff",
    )
  raw_grant_request(
    raw_investigator,
    unknown_relay_body,
    raw_investigator.csrf_token,
  )
  |> api.handle_at(context, 10_000)
  |> fn(response) { response.status }
  |> should.equal(400)

  let created =
    raw_grant_request(raw_investigator, body, raw_investigator.csrf_token)
    |> api.handle_at(context, 10_000)
  created.status |> should.equal(201)
  response.get_header(created, "cache-control") |> should.equal(Ok("no-store"))
  let assert Ok(decoded) =
    simulate.read_body(created)
    |> json.parse(raw_grant_response_decoder())
  decoded.expires_at_ms |> should.equal(15_000)
  let hash = raw_grant.token_hash(decoded.grant)
  let assert Ok(Some(saved)) = team_store.raw_capture_grant(metadata, hash)
  saved.actor |> should.equal("raw-allowed")
  saved.relay_id |> should.equal("relay-11223344556677889900aabb")

  let recorded = audit_store.snapshot(audit_log)
  audit.verify(recorded) |> should.equal(Ok(Nil))
  let assert [denied_role, denied_csrf, denied_relay, allowed] =
    recorded.entries
  [
    denied_role.outcome,
    denied_csrf.outcome,
    denied_relay.outcome,
    allowed.outcome,
  ]
  |> should.equal(["denied_rbac", "denied_csrf", "denied_input", "allowed"])
  recorded.entries
  |> list.all(fn(entry) { entry.action == "raw_capture.authorize" })
  |> should.be_true()

  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
  team_store.close(metadata) |> should.equal(Ok(Nil))
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
      None,
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
      None,
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
      None,
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

fn raw_grant_request(
  session: team_auth.Session,
  body: String,
  csrf_token: String,
) {
  simulate.request(http.Post, "/api/v1/raw-captures/authorize")
  |> simulate.string_body(body)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("origin", "https://hub.example")
  |> request.set_header("x-beamtrace-csrf", csrf_token)
  |> request.set_header(
    "cookie",
    "beamtrace_session="
      <> session.id
      <> "; beamtrace_csrf="
      <> session.csrf_token,
  )
}

fn raw_grant_response_decoder() -> decode.Decoder(RawGrantResponse) {
  use grant <- decode.field("grant", decode.string)
  use expires_at_ms <- decode.field("expires_at_ms", decode.int)
  decode.success(RawGrantResponse(grant, expires_at_ms))
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
