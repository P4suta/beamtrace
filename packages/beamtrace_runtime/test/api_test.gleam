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
import beamtrace_runtime/relay_payload
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
import sqlight
import v2_fixture
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

@external(erlang, "beamtrace_team_store_migration_test_ffi", "fresh_data_dir")
fn fresh_data_dir() -> String

@external(erlang, "beamtrace_team_store_migration_test_ffi", "fresh_store_path")
fn fresh_store_path() -> String

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
  simulate.request(http.Get, "/api/v9/health")
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

pub fn ready_is_versioned_and_available_after_the_handler_is_installed_test() {
  let response =
    simulate.request(http.Get, "/api/v1/ready")
    |> api.handle(api.test_context())
  response.status |> should.equal(200)
  simulate.read_body(response) |> should.equal("{\"status\":\"ready\"}")

  simulate.request(http.Post, "/api/v1/ready")
  |> api.handle(api.test_context())
  |> fn(response) { response.status }
  |> should.equal(405)
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
      local_instant: v2_fixture.instant(10),
      kind: types.Stop("complete"),
      evidence: types.Exact,
    )
  let manifest = v2_fixture.manifest("capture-api", ["fixture@host"])
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
  let url = "/api/v2/sessions/current/events?start=0&limit=1"

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
      "/api/v2/sessions/current/events?start=0&limit=1&q=no-such-event",
    )
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  no_matches.status |> should.equal(200)
  simulate.read_body(no_matches)
  |> string.contains("\"total\":0")
  |> should.be_true()

  simulate.request(
    http.Get,
    "/api/v2/sessions/current/events?start=0&limit=1001",
  )
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(400)
  local_auth.close(store)
}

pub fn local_capture_api_arms_pages_and_saves_a_real_session_test() {
  let captured = v2_fixture.capture_result([session_event("captured-root")])
  let capture_store =
    capture_session.new_with_backends_for_nodes(
      ["app@host"],
      fn(spec) {
        case
          spec.max_roots == 3,
          spec.preset == types.GenServer,
          spec.drain_timeout_ms == 1500
        {
          True, True, True -> Ok(captured)
          _, _, _ -> Error("capture_spec_not_forwarded")
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
    <> "\"capture_window_ms\":1000,\"drain_timeout_ms\":1500,\"max_events\":1000,"
    <> "\"max_bytes\":1000000,\"max_agent_mailbox\":100,"
    <> "\"max_roots\":3,\"preset\":\"gen-server\"}"

  simulate.request(http.Get, "/api/v2/targets/current/mfas?q=check&limit=20")
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(401)

  let candidates =
    simulate.request(http.Get, "/api/v2/targets/current/mfas?q=check&limit=20")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  candidates.status |> should.equal(200)
  simulate.read_body(candidates)
  |> string.contains("\"mfa\":\"shop:checkout/1\"")
  |> should.be_true()

  simulate.request(http.Post, "/api/v2/sessions/current/arm")
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
  simulate.request(http.Post, "/api/v2/sessions/current/arm")
  |> simulate.string_body(invalid_preset)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(400)

  let invalid_drain =
    "{\"trigger\":\"shop:checkout/1\",\"where\":null,"
    <> "\"capture_window_ms\":1000,\"drain_timeout_ms\":999,\"max_events\":1000,"
    <> "\"max_bytes\":1000000,\"max_agent_mailbox\":100,"
    <> "\"max_roots\":3,\"preset\":\"generic\"}"
  simulate.request(http.Post, "/api/v2/sessions/current/arm")
  |> simulate.string_body(invalid_drain)
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
  simulate.request(http.Post, "/api/v2/sessions/current/arm")
  |> simulate.string_body(invalid_roots)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
  |> api.handle_at(context, 1002)
  |> fn(response) { response.status }
  |> should.equal(400)

  let armed =
    simulate.request(http.Post, "/api/v2/sessions/current/arm")
    |> simulate.string_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1002)
  armed.status |> should.equal(202)
  let armed_body = simulate.read_body(armed)
  armed_body
  |> string.contains("\"status\":\"armed\"")
  |> should.be_true()
  capture_session.await(capture_store, 1000) |> should.equal(Ok(captured))

  let status =
    simulate.request(http.Get, "/api/v2/sessions/current")
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1003)
  status.status |> should.equal(200)
  let status_body = simulate.read_body(status)
  status_body
  |> string.contains("\"status\":\"sealed\"")
  |> should.be_true()
  status_body
  |> string.contains("\"delivery_verified\":true")
  |> should.be_true()

  let events =
    simulate.request(
      http.Get,
      "/api/v2/sessions/current/events?start=0&limit=10",
    )
    |> request.set_header("cookie", "beamtrace_session=" <> session.id)
    |> api.handle_at(context, 1003)
  events.status |> should.equal(200)
  let events_body = simulate.read_body(events)
  events_body
  |> string.contains("\"id\":\"captured-root\"")
  |> should.be_true()

  let path = "build/beamtrace-api-session-save.beamtrace"
  let saved =
    simulate.request(http.Post, "/api/v2/sessions/current/save")
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
  |> string.contains("\"evidence\":{\"kind\":\"inferred\"")
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
  let manifest = v2_fixture.manifest("api-compare", ["app@host"])
  storage.save(left, manifest, [session_event("left-root")])
  |> should.equal(Ok(Nil))
  storage.save(right, manifest, [
    session_event("right-root"),
    types.TraceEvent(
      ..session_event("right-extra"),
      kind: types.Stop("extra branch"),
      local_instant: v2_fixture.instant(20),
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
    local_instant: v2_fixture.instant(1),
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

pub fn team_trace_library_lists_locks_reads_holds_and_audits_test() {
  let relay_id = "relay-11223344556677889900aabb"
  let metadata_id = "00112233445566778899aabbccddeeff"
  let raw_id = "ffeeddccbbaa99887766554433221100"
  let blob_root = fresh_data_dir()
  let backend = blob_store.filesystem(blob_root)
  let assert Ok(metadata) = team_store.open(":memory:")
  seed_trace(
    metadata,
    backend,
    metadata_id,
    relay_id,
    "metadata",
    "metadata-event",
    1000,
  )
  seed_trace(metadata, backend, raw_id, relay_id, "raw", "raw-event", 2000)
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let assert Ok(audit_log) = audit_store.persistent(metadata)
  let viewer = team_session(sessions, "trace-viewer", [rbac.Viewer])
  let investigator =
    team_session(sessions, "trace-investigator", [rbac.Investigator])
  let raw_only = team_session(sessions, "trace-raw-only", [rbac.RawCaptureRole])
  let combined =
    team_session(sessions, "trace-combined", [
      rbac.Investigator,
      rbac.RawCaptureRole,
    ])
  let admin = team_session(sessions, "trace-admin", [rbac.Admin])
  let context =
    team_trace_context(sessions, annotation_store, audit_log, metadata, backend)

  simulate.request(http.Get, "/api/v2/traces")
  |> api.handle_at(context, 3000)
  |> fn(response) { response.status }
  |> should.equal(401)

  let listed =
    trace_request(http.Get, "/api/v2/traces?limit=1", viewer)
    |> api.handle_at(context, 3000)
  listed.status |> should.equal(200)
  let list_body = simulate.read_body(listed)
  list_body |> string.contains(raw_id) |> should.be_true()
  list_body |> string.contains("\"locked\":true") |> should.be_true()
  list_body |> string.contains("\"next_cursor\":\"") |> should.be_true()
  let final_page =
    trace_request(http.Get, "/api/v2/traces?limit=1&cursor=MQ", viewer)
    |> api.handle_at(context, 3000)
  final_page.status |> should.equal(200)
  simulate.read_body(final_page)
  |> string.contains("\"next_cursor\":null")
  |> should.be_true()
  trace_request(http.Get, "/api/v2/traces?cursor=eA", viewer)
  |> api.handle_at(context, 3000)
  |> fn(response) { response.status }
  |> should.equal(400)

  let detail =
    trace_request(http.Get, "/api/v2/traces/" <> raw_id, viewer)
    |> api.handle_at(context, 3000)
  detail.status |> should.equal(200)
  simulate.read_body(detail)
  |> string.contains("\"locked\":true")
  |> should.be_true()

  let metadata_events =
    trace_request(
      http.Get,
      "/api/v2/traces/" <> metadata_id <> "/events",
      viewer,
    )
    |> api.handle_at(context, 3001)
  metadata_events.status |> should.equal(200)
  simulate.read_body(metadata_events)
  |> string.contains("metadata-event")
  |> should.be_true()

  [viewer, investigator, raw_only]
  |> list.each(fn(session) {
    let denied =
      trace_request(http.Get, "/api/v2/traces/" <> raw_id <> "/events", session)
      |> api.handle_at(context, 3002)
    denied.status |> should.equal(403)
    simulate.read_body(denied)
    |> string.contains("raw-event")
    |> should.be_false()
  })
  [combined, admin]
  |> list.each(fn(session) {
    let allowed =
      trace_request(
        http.Get,
        "/api/v2/traces/" <> raw_id <> "/events?limit=200",
        session,
      )
      |> api.handle_at(context, 3003)
    allowed.status |> should.equal(200)
    simulate.read_body(allowed)
    |> string.contains("raw-event")
    |> should.be_true()
  })

  trace_hold_request(http.Post, raw_id, viewer, viewer.csrf_token)
  |> api.handle_at(context, 3004)
  |> fn(response) { response.status }
  |> should.equal(403)
  trace_hold_request(http.Post, raw_id, admin, "wrong")
  |> api.handle_at(context, 3004)
  |> fn(response) { response.status }
  |> should.equal(403)
  trace_hold_request(
    http.Post,
    "00000000000000000000000000000000",
    admin,
    admin.csrf_token,
  )
  |> api.handle_at(context, 3004)
  |> fn(response) { response.status }
  |> should.equal(404)
  let held =
    trace_hold_request(http.Post, raw_id, admin, admin.csrf_token)
    |> api.handle_at(context, 3004)
  held.status |> should.equal(200)
  simulate.read_body(held)
  |> string.contains("\"legal_hold\":true")
  |> should.be_true()
  let released =
    trace_hold_request(http.Delete, raw_id, admin, admin.csrf_token)
    |> api.handle_at(context, 3005)
  released.status |> should.equal(200)
  simulate.read_body(released)
  |> string.contains("\"legal_hold\":false")
  |> should.be_true()

  let recorded = audit_store.snapshot(audit_log)
  audit.verify(recorded) |> should.equal(Ok(Nil))
  recorded.entries
  |> list.filter(fn(entry) { entry.action == "raw_trace.read" })
  |> list.map(fn(entry) { entry.outcome })
  |> should.equal([
    "denied_rbac",
    "denied_rbac",
    "denied_rbac",
    "allowed",
    "allowed",
  ])
  recorded.entries
  |> list.filter(fn(entry) { entry.action == "trace.hold.create" })
  |> list.map(fn(entry) { entry.outcome })
  |> should.equal(["denied_rbac", "denied_csrf", "unknown_session", "allowed"])
  recorded.entries
  |> list.filter(fn(entry) { entry.action == "trace.hold.delete" })
  |> list.map(fn(entry) { entry.outcome })
  |> should.equal(["allowed"])
  team_store.audit_log(metadata) |> should.equal(Ok(recorded))

  simulate.request(http.Get, "/api/v1/relays/" <> relay_id <> "/frames")
  |> api.handle_at(context, 3006)
  |> fn(response) { response.status }
  |> should.equal(410)

  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
  team_store.close(metadata) |> should.equal(Ok(Nil))
}

pub fn raw_trace_acl_runs_before_filesystem_or_s3_fetch_test() {
  let relay_id = "relay-abcdef000000abcdef000000"
  let trace_id = "abcdefabcdefabcdefabcdefabcdefab"
  let assert Ok(metadata) = team_store.open(":memory:")
  let start = trace_start(trace_id, relay_id, "raw", 5000)
  let assert Ok(_) = team_store.begin_trace_session(metadata, start, 64)
  let missing =
    team_store.RelayFrameIndex(
      session_id: trace_id,
      relay_id: relay_id,
      sequence: 2,
      received_at_ms: 5001,
      mode: "exact",
      privacy: "raw",
      blob_key: "sessions/" <> trace_id <> "/events/missing.json",
      event_count: 1,
      bytes: 10,
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    )
  team_store.put_trace_frame(metadata, missing) |> should.equal(Ok(missing))
  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let assert Ok(audit_log) = audit_store.persistent(metadata)
  let viewer = team_session(sessions, "trace-prefetch-viewer", [rbac.Viewer])
  let assert Ok(s3) =
    blob_store.s3(
      endpoint: "https://objects.invalid",
      bucket: "beamtrace-test",
      region: "ap-northeast-1",
      prefix: "pre-fetch",
    )
  [blob_store.filesystem(fresh_data_dir()), s3]
  |> list.each(fn(backend) {
    let context =
      team_trace_context(
        sessions,
        annotation_store,
        audit_log,
        metadata,
        backend,
      )
    trace_request(http.Get, "/api/v2/traces/" <> trace_id <> "/events", viewer)
    |> api.handle_at(context, 5002)
    |> fn(response) { response.status }
    |> should.equal(403)
  })
  audit_store.snapshot(audit_log).entries
  |> list.map(fn(entry) { entry.outcome })
  |> should.equal(["denied_rbac", "denied_rbac"])

  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
  team_store.close(metadata) |> should.equal(Ok(Nil))
}

pub fn migrated_unknown_trace_is_incomplete_restart_safe_and_raw_locked_test() {
  let relay_id = "relay-00112233445566778899aabb"
  let trace_id = "legacy-" <> relay_id
  let database = fresh_store_path()
  let blob_root = fresh_data_dir()
  let blob_key = "relays/" <> relay_id <> "/frames/1.json"
  let policy = types.RawPolicy(["password"], 2, 64)
  let assert Ok(transport) =
    relay_payload.encode_raw("exact", string.repeat("C", 43), policy, [
      session_event("legacy-unknown-event"),
    ])
  let assert Ok(batch) = relay_payload.decode_for_ingest(transport)
  let assert Ok(blob) = blob_store.put(blob_root, blob_key, batch.canonical)

  let assert Ok(connection) = sqlight.open(database)
  sqlight.exec(
    "CREATE TABLE relay_frames (
       relay_id TEXT NOT NULL,
       sequence INTEGER NOT NULL,
       received_at_ms INTEGER NOT NULL,
       mode TEXT NOT NULL,
       blob_key TEXT NOT NULL,
       bytes INTEGER NOT NULL,
       sha256 TEXT NOT NULL,
       PRIMARY KEY (relay_id, sequence)
     );",
    connection,
  )
  |> should.be_ok()
  sqlight.query(
    "INSERT INTO relay_frames (
       relay_id, sequence, received_at_ms, mode, blob_key, bytes, sha256
     ) VALUES (?, 1, 1000, 'exact', ?, ?, ?);",
    on: connection,
    with: [
      sqlight.text(relay_id),
      sqlight.text(blob.key),
      sqlight.int(blob.bytes),
      sqlight.text(blob.sha256),
    ],
    expecting: decode.success(Nil),
  )
  |> should.be_ok()
  sqlight.close(connection) |> should.equal(Ok(Nil))

  // Opening performs the v1 -> session-scoped migration. Reopen once more to
  // prove the conservative privacy/delivery state is durable.
  let assert Ok(migrated) = team_store.open(database)
  team_store.close(migrated) |> should.equal(Ok(Nil))
  let assert Ok(metadata) = team_store.open(database)
  let assert Ok(Some(trace)) = team_store.trace_session(metadata, trace_id)
  trace.privacy |> should.equal("unknown")
  trace.delivery_status |> should.equal("failed")
  trace.active |> should.be_false()

  let sessions = team_auth.new()
  let annotation_store = annotations.new()
  let assert Ok(audit_log) = audit_store.persistent(metadata)
  let viewer = team_session(sessions, "unknown-viewer", [rbac.Viewer])
  let investigator =
    team_session(sessions, "unknown-investigator", [rbac.Investigator])
  let raw_only =
    team_session(sessions, "unknown-raw-only", [
      rbac.RawCaptureRole,
    ])
  let combined =
    team_session(sessions, "unknown-combined", [
      rbac.Investigator,
      rbac.RawCaptureRole,
    ])
  let admin = team_session(sessions, "unknown-admin", [rbac.Admin])
  let filesystem_context =
    team_trace_context(
      sessions,
      annotation_store,
      audit_log,
      metadata,
      blob_store.filesystem(blob_root),
    )

  let detail =
    trace_request(http.Get, "/api/v2/traces/" <> trace_id, viewer)
    |> api.handle_at(filesystem_context, 2000)
  detail.status |> should.equal(200)
  simulate.read_body(detail)
  |> string.contains("\"locked\":true")
  |> should.be_true()

  [viewer, investigator, raw_only]
  |> list.each(fn(session) {
    let denied =
      trace_request(
        http.Get,
        "/api/v2/traces/" <> trace_id <> "/events",
        session,
      )
      |> api.handle_at(filesystem_context, 2001)
    denied.status |> should.equal(403)
    simulate.read_body(denied)
    |> string.contains("legacy-unknown-event")
    |> should.be_false()
  })
  [combined, admin]
  |> list.each(fn(session) {
    let allowed =
      trace_request(
        http.Get,
        "/api/v2/traces/" <> trace_id <> "/events",
        session,
      )
      |> api.handle_at(filesystem_context, 2002)
    allowed.status |> should.equal(200)
    simulate.read_body(allowed)
    |> string.contains("legacy-unknown-event")
    |> should.be_true()
  })

  let assert Ok(s3) =
    blob_store.s3(
      endpoint: "https://objects.invalid",
      bucket: "beamtrace-test",
      region: "ap-northeast-1",
      prefix: "unknown-prefetch",
    )
  let s3_context =
    team_trace_context(sessions, annotation_store, audit_log, metadata, s3)
  trace_request(http.Get, "/api/v2/traces/" <> trace_id <> "/events", viewer)
  |> api.handle_at(s3_context, 2003)
  |> fn(response) { response.status }
  |> should.equal(403)

  audit_store.snapshot(audit_log).entries
  |> list.filter(fn(entry) { entry.action == "raw_trace.read" })
  |> list.map(fn(entry) { entry.outcome })
  |> should.equal([
    "denied_rbac",
    "denied_rbac",
    "denied_rbac",
    "allowed",
    "allowed",
    "denied_rbac",
  ])

  audit_store.close(audit_log)
  annotations.close(annotation_store)
  team_auth.close(sessions)
  team_store.close(metadata) |> should.equal(Ok(Nil))
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

fn seed_trace(
  store: team_store.Store,
  backend: blob_store.Backend,
  trace_id: String,
  relay_id: String,
  privacy: String,
  event_id: String,
  timestamp_ms: Int,
) -> Nil {
  let start = trace_start(trace_id, relay_id, privacy, timestamp_ms)
  let assert Ok(_) = team_store.begin_trace_session(store, start, 64)
  let #(payload, classification) = case privacy {
    "metadata" -> {
      let assert Ok(encoded) =
        relay_payload.encode("exact", [session_event(event_id)])
      #(encoded, relay_inbox.Metadata)
    }
    "raw" -> {
      let policy = types.RawPolicy(["password"], 2, 64)
      let assert Ok(transport) =
        relay_payload.encode_raw("exact", string.repeat("A", 43), policy, [
          session_event(event_id),
        ])
      let assert Ok(decoded) = relay_payload.decode_for_ingest(transport)
      #(decoded.canonical, relay_inbox.Raw)
    }
    _ -> panic as "invalid test privacy"
  }
  let assert Ok(_) =
    relay_archive.persist_session_events_classified_with(
      store,
      backend,
      trace_id,
      relay_id,
      2,
      relay_archive.Exact,
      classification,
      payload,
      timestamp_ms + 2,
      event_count: 1,
    )
  let assert Ok(_) =
    team_store.finish_trace_session(
      store,
      trace_id,
      relay_id,
      "delivered",
      timestamp_ms + 3,
      timestamp_ms + 4,
    )
  Nil
}

fn trace_start(
  trace_id: String,
  relay_id: String,
  privacy: String,
  timestamp_ms: Int,
) -> team_store.TraceSession {
  team_store.TraceSession(
    id: trace_id,
    relay_id: relay_id,
    project: "shop",
    environment: "prod",
    node: "app@host",
    module_: "shop",
    function_: "checkout",
    arity: 1,
    mode: "exact",
    privacy: privacy,
    started_at_ms: timestamp_ms,
    received_at_ms: timestamp_ms + 1,
    ended_at_ms: 0,
    last_received_at_ms: timestamp_ms + 1,
    delivery_status: "active",
    event_count: 0,
    legal_hold: False,
    active: True,
  )
}

fn team_trace_context(
  sessions: team_auth.Store,
  annotation_store: annotations.Store,
  audit_log: audit_store.Store,
  metadata: team_store.Store,
  backend: blob_store.Backend,
) -> api.Context {
  api.Context(
    "0.2.0",
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
}

fn trace_request(
  method: http.Method,
  path: String,
  session: team_auth.Session,
) {
  simulate.request(method, path)
  |> request.set_header("cookie", "beamtrace_session=" <> session.id)
}

fn trace_hold_request(
  method: http.Method,
  trace_id: String,
  session: team_auth.Session,
  csrf_token: String,
) {
  trace_request(method, "/api/v2/traces/" <> trace_id <> "/hold", session)
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
