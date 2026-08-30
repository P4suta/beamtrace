// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/annotations
import beamtrace_runtime/api
import beamtrace_runtime/audit
import beamtrace_runtime/audit_store
import beamtrace_runtime/blob_store
import beamtrace_runtime/capture_session
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/local_auth
import beamtrace_runtime/rbac
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_client
import beamtrace_runtime/relay_wire
import beamtrace_runtime/server
import beamtrace_runtime/team_config
import beamtrace_runtime/team_store
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import v2_fixture
import wisp/simulate

pub fn listener_start_failure_closes_bootstrap_store_test() {
  let #(store, token) = local_auth.new_at(1000, 100)

  server.cleanup_start_error(store, "address_in_use")
  |> should.equal(Error("address_in_use"))

  local_auth.exchange(store, token, 1001)
  |> should.equal(Error("closed"))
}

pub fn occupied_listener_returns_a_descriptive_error_test() {
  let result =
    with_occupied_loopback_port(fn(port) {
      server.start(
        bind: "127.0.0.1",
        port: port,
        mode: api.Local,
        secret_key_base: "test-secret-key-base",
        static_root: None,
        archive_path: None,
      )
    })

  let assert Error(error) = result
  error
  |> string.starts_with("could not bind 127.0.0.1:")
  |> should.be_true()
}

pub fn local_server_becomes_ready_then_closes_cleanly_on_sigterm_test() {
  server_signal_lifecycle() |> should.equal(Ok(Nil))
}

pub fn local_runtime_owns_and_closes_the_attached_capture_session_test() {
  let capture_store =
    capture_session.new_with_backend(fn(_spec) {
      Ok(v2_fixture.capture_result([]))
    })
  let runtime = server.new_local(None, None, Some(capture_store))

  runtime.context.local_capture |> should.equal(Some(capture_store))
  runtime.context.mode |> should.equal(api.Local)
  runtime.bootstrap_token
  |> string.length
  |> fn(length) { length > 20 }
  |> should.be_true()

  server.close_local(runtime)
  capture_session.status(capture_store)
  |> should.equal(capture_session.Failed("session_closed"))
}

pub fn team_runtime_wires_oidc_and_one_time_relay_enrollment_without_cookie_test() {
  let config = team_configuration(fresh_data_dir(), 7)
  let assert Ok(runtime) = server.new_team(config, None, None, 1000)
  runtime.context.mode |> should.equal(api.Team)
  runtime.context.local_auth |> should.equal(None)
  team_store.journal_mode(runtime.metadata_store)
  |> should.equal(Ok("wal"))
  runtime.blob_root
  |> string.ends_with("/blobs")
  |> should.be_true()
  runtime.relay_quota.max_events |> should.equal(10_000)
  runtime.relay_quota.max_bytes |> should.equal(64_000_000)

  let oidc_start =
    simulate.request(http.Get, "/auth/oidc/start")
    |> api.handle_at(runtime.context, 1001)
  oidc_start.status |> should.equal(303)
  let assert Ok(location) = response.get_header(oidc_start, "location")
  location
  |> string.starts_with("https://id.example/authorize?")
  |> should.be_true()

  let identity = relay_channel.new_identity()
  let assert Ok(enrollment) =
    relay_client.prepare_enrollment(
      "https://hub.example",
      runtime.enrollment_code,
      identity,
    )
  let request =
    simulate.request(http.Post, "/api/relay/v1/enroll")
    |> simulate.string_body(enrollment.body)
    |> request.set_header("content-type", "application/json")
  let enrolled = api.handle_at(request, runtime.context, 1002)
  enrolled.status |> should.equal(201)
  simulate.read_body(enrolled)
  |> string.contains(
    "\"channel_url\":\"wss://hub.example/api/relay/v1/channel/",
  )
  |> should.be_true()
  api.handle_at(request, runtime.context, 1003).status |> should.equal(409)

  let enrollment_audit = audit_store.snapshot(runtime.audit)
  audit.verify(enrollment_audit) |> should.equal(Ok(Nil))
  let assert [allowed, reused] = enrollment_audit.entries
  [allowed.action, allowed.outcome, reused.action, reused.outcome]
  |> should.equal([
    "relay.enroll",
    "allowed",
    "relay.enroll",
    "denied_reuse",
  ])
  [allowed.resource, reused.resource]
  |> list.any(fn(value) { string.contains(value, runtime.enrollment_code) })
  |> should.be_false()

  server.close_team(runtime)
  let assert Ok(reopened) = team_store.open(runtime.database_path)
  team_store.journal_mode(reopened) |> should.equal(Ok("wal"))
  team_store.close(reopened) |> should.equal(Ok(Nil))
}

pub fn team_restart_applies_configured_relay_retention_test() {
  let config = team_configuration("build/team-retention-data-test", 1)
  let relay_id = "relay-a1b2c3d4e5f60718293a4b5c"
  let assert Ok(seed) = server.new_team(config, None, None, 1000)
  relay_archive.persist(
    seed.metadata_store,
    seed.blob_root,
    relay_id,
    1,
    relay_archive.Live,
    "expired",
    1000,
  )
  |> should.be_ok
  server.close_team(seed)

  let assert Ok(restarted) =
    server.new_team(config, None, None, 86_400_000 + 1001)
  team_store.relay_frame_count(restarted.metadata_store, relay_id)
  |> should.equal(Ok(0))
  server.close_team(restarted)
}

pub fn team_runtime_routes_relay_archives_to_the_configured_s3_backend_test() {
  let base = team_configuration(fresh_data_dir(), 7)
  let config =
    team_config.Config(
      ..base,
      blob_backend: team_config.S3Blobs(
        "https://objects.example",
        "beamtrace-prod",
        "ap-northeast-1",
        "captures/team-a",
      ),
    )
  let assert Ok(runtime) = server.new_team(config, None, None, 2000)
  let assert blob_store.S3(_) = runtime.blob_backend
  let assert Some(security) = runtime.context.team_security
  let assert Some(api.RelayArchiveBackend(_, blob_store.S3(_))) =
    security.relay_archive
  server.close_team(runtime)
}

pub fn team_restart_restores_annotations_and_audit_chain_test() {
  let config = team_configuration(fresh_data_dir(), 7)
  let assert Ok(initial) = server.new_team(config, None, None, 3000)
  let assert Ok(annotation) =
    annotations.append(
      initial.annotation_store,
      "event-restart",
      "persistent diagnosis",
      "investigator-7",
      3001,
    )
  audit_store.append(
    initial.audit,
    3001,
    "investigator-7",
    "annotation.create",
    "event:event-restart",
    "allowed",
  )
  server.close_team(initial)

  let assert Ok(restarted) = server.new_team(config, None, None, 3002)
  annotations.list(restarted.annotation_store)
  |> should.equal([annotation])
  let restored_audit = audit_store.snapshot(restarted.audit)
  audit.verify(restored_audit) |> should.equal(Ok(Nil))
  let assert [entry] = restored_audit.entries
  entry.resource |> should.equal("event:event-restart")
  server.close_team(restarted)
}

pub fn team_restart_authenticates_an_already_enrolled_relay_test() {
  let config = team_configuration(fresh_data_dir(), 7)
  let identity = relay_channel.new_identity()
  let assert Ok(initial) = server.new_team(config, None, None, 6000)
  let assert Ok(relay) =
    enrollment_store.consume(
      initial.enrollment,
      initial.enrollment_code,
      identity.public_key,
      6001,
    )
  server.close_team(initial)

  let assert Ok(restarted) = server.new_team(config, None, None, 6002)
  let hello =
    relay_wire.prepare_hello(identity, relay.id, 6003, <<0xbb:size(8)-unit(16)>>)
  relay_wire.authenticate(restarted.enrollment, hello, 6003)
  |> should.equal(Ok(relay))
  server.close_team(restarted)
}

pub fn only_the_versioned_get_channel_path_is_routed_to_websocket_test() {
  server.relay_channel_route(http.Get, [
    "api",
    "relay",
    "v1",
    "channel",
    "relay-aabbccddeeff001122334455",
  ])
  |> should.equal(Some("relay-aabbccddeeff001122334455"))
  server.relay_channel_route(http.Post, [
    "api",
    "relay",
    "v1",
    "channel",
    "relay-aabbccddeeff001122334455",
  ])
  |> should.equal(None)
  server.relay_channel_route(http.Get, [
    "api",
    "relay",
    "v1",
    "channel",
    "../admin",
  ])
  |> should.equal(None)
  server.relay_channel_route(http.Get, ["api", "relay", "v2", "channel", "x"])
  |> should.equal(None)
}

fn team_configuration(data_dir: String, retention_days: Int) {
  team_config.Config(
    bind: "127.0.0.1",
    data_dir: data_dir,
    port: 4040,
    origin: "https://hub.example",
    authorization_endpoint: "https://id.example/authorize",
    token_endpoint: "https://id.example/token",
    issuer: "https://id.example",
    client_id: "beamtrace",
    redirect_uri: "https://hub.example/auth/oidc/callback",
    jwks_json: "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"key-1\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"AQ\",\"e\":\"Aw\"}]}",
    group_roles: [#("beam-viewers", rbac.Viewer)],
    project: "shop",
    environment: "prod",
    retention_days: retention_days,
    raw_retention_days: 1,
    relay_max_events: 10_000,
    relay_max_bytes: 64_000_000,
    enrollment_ttl_ms: 60_000,
    blob_backend: team_config.FilesystemBlobs,
  )
}

@external(erlang, "beamtrace_team_store_migration_test_ffi", "fresh_data_dir")
fn fresh_data_dir() -> String

@external(erlang, "beamtrace_server_test_ffi", "with_occupied_loopback_port")
fn with_occupied_loopback_port(run: fn(Int) -> a) -> a

@external(erlang, "beamtrace_server_test_ffi", "server_signal_lifecycle")
fn server_signal_lifecycle() -> Result(Nil, String)
