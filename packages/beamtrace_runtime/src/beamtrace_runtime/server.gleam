// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/annotations
import beamtrace_runtime/api
import beamtrace_runtime/audit_store
import beamtrace_runtime/blob_store
import beamtrace_runtime/capture_session
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/id_token
import beamtrace_runtime/internal/version as runtime_version
import beamtrace_runtime/local_auth
import beamtrace_runtime/log
import beamtrace_runtime/oidc_flow
import beamtrace_runtime/relay_archive
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_ingest
import beamtrace_runtime/relay_websocket
import beamtrace_runtime/team_auth
import beamtrace_runtime/team_config
import beamtrace_runtime/team_store
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import mist
import wisp/wisp_mist

const retention_interval_ms = 3_600_000

pub type TeamRuntime {
  TeamRuntime(
    context: api.Context,
    enrollment_code: String,
    sessions: team_auth.Store,
    annotation_store: annotations.Store,
    audit: audit_store.Store,
    attempts: oidc_flow.Store,
    enrollment: enrollment_store.Store,
    inbox: relay_inbox.Store,
    metadata_store: team_store.Store,
    database_path: String,
    blob_root: String,
    blob_backend: blob_store.Backend,
    relay_quota: relay_ingest.Quota,
    retention_worker: process.Pid,
  )
}

pub type LocalRuntime {
  LocalRuntime(
    context: api.Context,
    bootstrap_token: String,
    auth_store: local_auth.Store,
    capture_store: Option(capture_session.Store),
  )
}

pub fn start(
  bind bind: String,
  port port: Int,
  mode mode: api.ServerMode,
  secret_key_base secret_key_base: String,
  static_root static_root: Option(String),
  archive_path archive_path: Option(String),
) -> Result(Nil, String) {
  start_local(
    bind,
    port,
    mode,
    secret_key_base,
    static_root,
    archive_path,
    None,
    False,
    "",
  )
}

/// Start a local workspace and optionally launch its one-time bootstrap URL.
/// Browser launch failure is reported but never stops the bound server.
pub fn start_with_browser(
  bind bind: String,
  port port: Int,
  mode mode: api.ServerMode,
  secret_key_base secret_key_base: String,
  static_root static_root: Option(String),
  archive_path archive_path: Option(String),
  open_browser open_browser: Bool,
) -> Result(Nil, String) {
  start_local(
    bind,
    port,
    mode,
    secret_key_base,
    static_root,
    archive_path,
    None,
    open_browser,
    "",
  )
}

/// Start a local comparison workspace whose bounded path list is consumed
/// once from the bootstrap redirect. The browser history is cleaned by the Web
/// client immediately after initialization.
pub fn start_compare_with_browser(
  bind bind: String,
  port port: Int,
  secret_key_base secret_key_base: String,
  static_root static_root: Option(String),
  archive_path archive_path: Option(String),
  paths paths: List(String),
  open_browser open_browser: Bool,
) -> Result(Nil, String) {
  let query = "?compare=" <> uri.percent_encode(string.join(paths, "\n"))
  start_local(
    bind,
    port,
    api.Local,
    secret_key_base,
    static_root,
    archive_path,
    None,
    open_browser,
    query,
  )
}

pub fn start_attached(
  bind bind: String,
  port port: Int,
  mode mode: api.ServerMode,
  secret_key_base secret_key_base: String,
  static_root static_root: Option(String),
  capture_store capture_store: capture_session.Store,
) -> Result(Nil, String) {
  start_local(
    bind,
    port,
    mode,
    secret_key_base,
    static_root,
    None,
    Some(capture_store),
    False,
    "",
  )
}

pub fn start_attached_with_browser(
  bind bind: String,
  port port: Int,
  mode mode: api.ServerMode,
  secret_key_base secret_key_base: String,
  static_root static_root: Option(String),
  capture_store capture_store: capture_session.Store,
  open_browser open_browser: Bool,
) -> Result(Nil, String) {
  start_local(
    bind,
    port,
    mode,
    secret_key_base,
    static_root,
    None,
    Some(capture_store),
    open_browser,
    "",
  )
}

pub fn new_local(
  static_root: Option(String),
  archive_path: Option(String),
  capture_store: Option(capture_session.Store),
) -> LocalRuntime {
  let #(auth_store, bootstrap_token) = local_auth.new(60_000)
  let context =
    api.Context(
      tool_version: runtime_version.current,
      mode: api.Local,
      static_root: static_root,
      local_auth: Some(auth_store),
      archive_path: archive_path,
      relay_enrollment: None,
      team_security: None,
      local_capture: capture_store,
    )
  LocalRuntime(context, bootstrap_token, auth_store, capture_store)
}

pub fn close_local(runtime: LocalRuntime) -> Nil {
  case runtime.capture_store {
    Some(store) -> capture_session.close(store)
    None -> Nil
  }
  local_auth.close(runtime.auth_store)
}

fn start_local(
  bind: String,
  port: Int,
  _mode: api.ServerMode,
  secret_key_base: String,
  static_root: Option(String),
  archive_path: Option(String),
  capture_store: Option(capture_session.Store),
  open_browser: Bool,
  bootstrap_query: String,
) -> Result(Nil, String) {
  let runtime = new_local(static_root, archive_path, capture_store)
  let listener =
    fn(request) { api.handle(request, runtime.context) }
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.bind(bind)
    |> mist.port(port)
    |> mist.after_start(fn(actual_port, _scheme, _address) {
      let url = local_url(bind, actual_port)
      log.emit(log.Info, "server.ready", [
        log.Field("mode", "local"),
        log.Field("bind", bind),
        log.Field("port", int.to_string(actual_port)),
      ])
      io.println("BeamTrace workspace: " <> url)
      let bootstrap_url =
        url <> "/bootstrap/" <> runtime.bootstrap_token <> bootstrap_query
      case open_browser {
        False -> io.println("One-time bootstrap URL: " <> bootstrap_url)
        True ->
          case launch_browser(bootstrap_url) {
            Ok(Nil) -> io.println("Opened the one-time bootstrap URL.")
            Error(reason) -> {
              io.println_error("Could not open the default browser: " <> reason)
              io.println("One-time bootstrap URL: " <> bootstrap_url)
            }
          }
      }
    })

  let previous_trap_exit = begin_listener_start()
  let listener_start = mist.start(listener)
  end_listener_start(previous_trap_exit)
  case listener_start {
    Ok(started) -> {
      let outcome = await_shutdown(started.pid)
      stop_listener(started.pid)
      close_local(runtime)
      log.emit(log.Info, "server.closed", [log.Field("mode", "local")])
      outcome
    }
    Error(_error) -> {
      close_local(runtime)
      log.emit(log.Error, "server.bind_failed", [
        log.Field("mode", "local"),
        log.Field("bind", bind),
        log.Field("port", int.to_string(port)),
      ])
      Error("could not bind " <> bind <> ":" <> int.to_string(port))
    }
  }
}

pub fn cleanup_start_error(
  auth_store: local_auth.Store,
  error: String,
) -> Result(Nil, String) {
  local_auth.close(auth_store)
  Error(error)
}

pub fn new_team(
  config: team_config.Config,
  static_root: Option(String),
  archive_path: Option(String),
  now_ms: Int,
) -> Result(TeamRuntime, String) {
  use Nil <- result_try(case id_token.validate_signing_jwks(config.jwks_json) {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> Error("invalid OIDC public signing JWKS")
  })
  use paths <- result_try(prepare_data_paths(config.data_dir))
  let #(database_path, blob_root) = paths
  use blob_backend <- result_try(configured_blob_backend(
    config.blob_backend,
    blob_root,
  ))
  use metadata_store <- result_try(team_store.open(database_path))
  let metadata_cutoff_ms =
    int.max(now_ms - config.retention_days * 86_400_000, 0)
  let raw_cutoff_ms =
    int.max(now_ms - config.raw_retention_days * 86_400_000, 0)
  use Nil <- result_try(initialize_retention(
    metadata_store,
    blob_backend,
    metadata_cutoff_ms,
    raw_cutoff_ms,
  ))
  let sessions = team_auth.new()
  let annotation_store = annotations.persistent(metadata_store)
  use audit <- result_try(open_persistent_audit(
    metadata_store,
    sessions,
    annotation_store,
  ))
  let attempts = oidc_flow.new()
  use enrollment_pair <- result_try(open_persistent_enrollment(
    metadata_store,
    sessions,
    annotation_store,
    audit,
    attempts,
    now_ms,
    config.enrollment_ttl_ms,
  ))
  let #(enrollment, enrollment_code) = enrollment_pair
  let inbox = relay_inbox.new(max_frames: 4096, max_bytes: 64_000_000)
  let relay_quota =
    relay_ingest.Quota(
      max_events: config.relay_max_events,
      max_bytes: config.relay_max_bytes,
    )
  let retention_worker =
    process.spawn_unlinked(fn() {
      retention_loop(
        metadata_store,
        blob_backend,
        config.retention_days,
        config.raw_retention_days,
      )
    })
  let provider =
    api.production_oidc_provider(
      authorization_endpoint: config.authorization_endpoint,
      token_endpoint: config.token_endpoint,
      client_id: config.client_id,
      redirect_uri: config.redirect_uri,
      issuer: config.issuer,
      jwks_json: config.jwks_json,
      attempts: attempts,
      group_roles: config.group_roles,
      project: config.project,
      environment: config.environment,
    )
  let security =
    api.TeamSecurity(
      sessions: sessions,
      annotations: annotation_store,
      audit: audit,
      origin: config.origin,
      oidc: Some(provider),
      relay_inbox: Some(inbox),
      relay_archive: Some(api.RelayArchiveBackend(metadata_store, blob_backend)),
    )
  let context =
    api.Context(
      tool_version: runtime_version.current,
      mode: api.Team,
      static_root: static_root,
      local_auth: None,
      archive_path: archive_path,
      relay_enrollment: Some(api.RelayEnrollment(
        enrollment,
        websocket_origin(config.origin),
      )),
      team_security: Some(security),
      local_capture: None,
    )
  Ok(TeamRuntime(
    context: context,
    enrollment_code: enrollment_code,
    sessions: sessions,
    annotation_store: annotation_store,
    audit: audit,
    attempts: attempts,
    enrollment: enrollment,
    inbox: inbox,
    metadata_store: metadata_store,
    database_path: database_path,
    blob_root: blob_root,
    blob_backend: blob_backend,
    relay_quota: relay_quota,
    retention_worker: retention_worker,
  ))
}

fn retention_loop(
  metadata_store: team_store.Store,
  blob_backend: blob_store.Backend,
  metadata_days: Int,
  raw_days: Int,
) {
  process.sleep(retention_interval_ms)
  let now_ms = local_auth.now_ms()
  let metadata_cutoff_ms = int.max(now_ms - metadata_days * 86_400_000, 0)
  let raw_cutoff_ms = int.max(now_ms - raw_days * 86_400_000, 0)
  case
    prune_all(metadata_store, blob_backend, metadata_cutoff_ms, raw_cutoff_ms)
  {
    Ok(Nil) -> Nil
    Error(_) -> log.emit(log.Error, "retention.prune_failed", [])
  }
  retention_loop(metadata_store, blob_backend, metadata_days, raw_days)
}

fn initialize_retention(
  metadata_store: team_store.Store,
  blob_backend: blob_store.Backend,
  metadata_cutoff_ms: Int,
  raw_cutoff_ms: Int,
) -> Result(Nil, String) {
  case
    prune_all(metadata_store, blob_backend, metadata_cutoff_ms, raw_cutoff_ms)
  {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _ = team_store.close(metadata_store)
      Error(error)
    }
  }
}

fn prune_all(
  metadata_store: team_store.Store,
  blob_backend: blob_store.Backend,
  metadata_cutoff_ms: Int,
  raw_cutoff_ms: Int,
) -> Result(Nil, String) {
  case
    relay_archive.prune_sessions_before_with(
      metadata_store,
      blob_backend,
      metadata_cutoff_ms: metadata_cutoff_ms,
      raw_cutoff_ms: raw_cutoff_ms,
      limit: 1000,
    )
  {
    Error(error) -> Error(error)
    Ok(relay_archive.PruneResult(_, _, True)) ->
      prune_all(metadata_store, blob_backend, metadata_cutoff_ms, raw_cutoff_ms)
    Ok(relay_archive.PruneResult(_, _, False)) -> Ok(Nil)
  }
}

pub fn close_team(runtime: TeamRuntime) -> Nil {
  stop_worker(runtime.retention_worker)
  relay_inbox.close(runtime.inbox)
  enrollment_store.close(runtime.enrollment)
  oidc_flow.close(runtime.attempts)
  audit_store.close(runtime.audit)
  annotations.close(runtime.annotation_store)
  team_auth.close(runtime.sessions)
  let _ = team_store.close(runtime.metadata_store)
  Nil
}

fn open_persistent_audit(
  metadata_store: team_store.Store,
  sessions: team_auth.Store,
  annotation_store: annotations.Store,
) -> Result(audit_store.Store, String) {
  case audit_store.persistent(metadata_store) {
    Ok(store) -> Ok(store)
    Error(reason) -> {
      annotations.close(annotation_store)
      team_auth.close(sessions)
      let _ = team_store.close(metadata_store)
      Error(reason)
    }
  }
}

fn open_persistent_enrollment(
  metadata_store: team_store.Store,
  sessions: team_auth.Store,
  annotation_store: annotations.Store,
  audit: audit_store.Store,
  attempts: oidc_flow.Store,
  now_ms: Int,
  ttl_ms: Int,
) -> Result(#(enrollment_store.Store, String), String) {
  case enrollment_store.persistent_at(metadata_store, now_ms, ttl_ms) {
    Ok(enrollment) -> Ok(enrollment)
    Error(reason) -> {
      oidc_flow.close(attempts)
      audit_store.close(audit)
      annotations.close(annotation_store)
      team_auth.close(sessions)
      let _ = team_store.close(metadata_store)
      Error(reason)
    }
  }
}

pub fn start_team(
  config config: team_config.Config,
  secret_key_base secret_key_base: String,
  static_root static_root: Option(String),
  archive_path archive_path: Option(String),
) -> Result(Nil, String) {
  case new_team(config, static_root, archive_path, local_auth.now_ms()) {
    Error(error) -> Error(error)
    Ok(runtime) -> {
      let http_handler =
        fn(incoming) { api.handle(incoming, runtime.context) }
        |> wisp_mist.handler(secret_key_base)
      let handler = fn(incoming: Request(mist.Connection)) {
        case
          relay_channel_route(incoming.method, request.path_segments(incoming))
        {
          Some(relay_id) ->
            relay_websocket.upgrade(
              incoming,
              runtime.enrollment,
              runtime.inbox,
              runtime.metadata_store,
              runtime.blob_backend,
              runtime.relay_quota,
              relay_id,
              config.project,
              config.environment,
            )
          None -> http_handler(incoming)
        }
      }
      let listener =
        handler
        |> mist.new
        |> mist.bind(config.bind)
        |> mist.port(config.port)
        |> mist.after_start(fn(_actual_port, _scheme, _address) {
          log.emit(log.Info, "server.ready", [
            log.Field("mode", "team"),
            log.Field("bind", config.bind),
            log.Field("port", int.to_string(config.port)),
          ])
          io.println("BeamTrace team workspace: " <> config.origin)
          io.println(
            "One-time relay enrollment code: " <> runtime.enrollment_code,
          )
        })

      let previous_trap_exit = begin_listener_start()
      let listener_start = mist.start(listener)
      end_listener_start(previous_trap_exit)
      case listener_start {
        Ok(started) -> {
          let outcome = await_shutdown(started.pid)
          stop_listener(started.pid)
          close_team(runtime)
          log.emit(log.Info, "server.closed", [log.Field("mode", "team")])
          outcome
        }
        Error(_error) -> {
          close_team(runtime)
          log.emit(log.Error, "server.bind_failed", [
            log.Field("mode", "team"),
            log.Field("bind", config.bind),
            log.Field("port", int.to_string(config.port)),
          ])
          Error(
            "could not bind "
            <> config.bind
            <> ":"
            <> int.to_string(config.port),
          )
        }
      }
    }
  }
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn configured_blob_backend(
  config: team_config.BlobBackendConfig,
  filesystem_root: String,
) -> Result(blob_store.Backend, String) {
  case config {
    team_config.FilesystemBlobs -> Ok(blob_store.filesystem(filesystem_root))
    team_config.S3Blobs(endpoint, bucket, region, prefix) ->
      blob_store.s3(endpoint, bucket, region, prefix)
  }
}

@external(erlang, "beamtrace_team_store_ffi", "prepare_data_paths")
fn prepare_data_paths(data_dir: String) -> Result(#(String, String), String)

pub fn relay_channel_route(
  method: http.Method,
  segments: List(String),
) -> Option(String) {
  case method, segments {
    http.Get, ["api", "relay", "v1", "channel", relay_id] ->
      case valid_relay_id(relay_id) {
        True -> Some(relay_id)
        False -> None
      }
    _, _ -> None
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

fn websocket_origin(origin: String) -> String {
  case string.starts_with(origin, "https://") {
    True -> "wss://" <> string.drop_start(origin, 8)
    False -> origin
  }
}

fn local_url(bind: String, port: Int) -> String {
  let host = case string.contains(bind, ":") {
    True -> "[" <> bind <> "]"
    False -> bind
  }
  "http://" <> host <> ":" <> int.to_string(port)
}

@external(erlang, "beamtrace_server_ffi", "await_shutdown")
fn await_shutdown(listener: process.Pid) -> Result(Nil, String)

@external(erlang, "beamtrace_server_ffi", "begin_listener_start")
fn begin_listener_start() -> Bool

@external(erlang, "beamtrace_server_ffi", "end_listener_start")
fn end_listener_start(previous_trap_exit: Bool) -> Nil

@external(erlang, "beamtrace_server_ffi", "stop_listener")
fn stop_listener(listener: process.Pid) -> Nil

@external(erlang, "beamtrace_server_ffi", "stop_worker")
fn stop_worker(worker: process.Pid) -> Nil

@external(erlang, "beamtrace_server_ffi", "open_browser")
fn launch_browser(url: String) -> Result(Nil, String)
