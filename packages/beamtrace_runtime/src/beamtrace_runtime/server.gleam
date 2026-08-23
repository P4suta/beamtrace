// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/annotations
import beamtrace_runtime/api
import beamtrace_runtime/audit_store
import beamtrace_runtime/blob_store
import beamtrace_runtime/capture_session
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/internal/version as runtime_version
import beamtrace_runtime/local_auth
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
import mist
import wisp/wisp_mist

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
) -> Result(Nil, String) {
  let runtime = new_local(static_root, archive_path, capture_store)
  io.println(
    "One-time bootstrap URL: http://"
    <> bind
    <> ":"
    <> int.to_string(port)
    <> "/bootstrap/"
    <> runtime.bootstrap_token,
  )
  let listener =
    fn(request) { api.handle(request, runtime.context) }
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.bind(bind)
    |> mist.port(port)

  case mist.start(listener) {
    Ok(_) -> {
      process.sleep_forever()
      close_local(runtime)
      Ok(Nil)
    }
    Error(error) -> {
      close_local(runtime)
      Error(string.inspect(error))
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
  use paths <- result_try(prepare_data_paths(config.data_dir))
  let #(database_path, blob_root) = paths
  use blob_backend <- result_try(configured_blob_backend(
    config.blob_backend,
    blob_root,
  ))
  use metadata_store <- result_try(team_store.open(database_path))
  let retention_cutoff_ms =
    int.max(now_ms - config.retention_days * 86_400_000, 0)
  use Nil <- result_try(initialize_retention(
    metadata_store,
    blob_backend,
    retention_cutoff_ms,
  ))
  let sessions = team_auth.new()
  let annotation_store = annotations.persistent(metadata_store)
  use audit <- result_try(open_persistent_audit(metadata_store))
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
  ))
}

fn initialize_retention(
  metadata_store: team_store.Store,
  blob_backend: blob_store.Backend,
  cutoff_ms: Int,
) -> Result(Nil, String) {
  case prune_all(metadata_store, blob_backend, cutoff_ms) {
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
  cutoff_ms: Int,
) -> Result(Nil, String) {
  case
    relay_archive.prune_before_with(
      metadata_store,
      blob_backend,
      cutoff_ms: cutoff_ms,
      limit: 1000,
    )
  {
    Error(error) -> Error(error)
    Ok(relay_archive.PruneResult(_, _, True)) ->
      prune_all(metadata_store, blob_backend, cutoff_ms)
    Ok(relay_archive.PruneResult(_, _, False)) -> Ok(Nil)
  }
}

pub fn close_team(runtime: TeamRuntime) -> Nil {
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
) -> Result(audit_store.Store, String) {
  case audit_store.persistent(metadata_store) {
    Ok(store) -> Ok(store)
    Error(reason) -> {
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
      io.println("BeamTrace team workspace: " <> config.origin)
      io.println("One-time relay enrollment code: " <> runtime.enrollment_code)
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
            )
          None -> http_handler(incoming)
        }
      }
      let listener =
        handler
        |> mist.new
        |> mist.bind(config.bind)
        |> mist.port(config.port)

      case mist.start(listener) {
        Ok(_) -> {
          process.sleep_forever()
          Ok(Nil)
        }
        Error(error) -> {
          close_team(runtime)
          Error(string.inspect(error))
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
