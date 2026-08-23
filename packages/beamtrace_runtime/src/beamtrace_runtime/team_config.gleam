// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/rbac
import beamtrace_runtime/s3_blob
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

pub type Config {
  Config(
    bind: String,
    data_dir: String,
    port: Int,
    origin: String,
    authorization_endpoint: String,
    token_endpoint: String,
    issuer: String,
    client_id: String,
    redirect_uri: String,
    jwks_json: String,
    group_roles: List(#(String, rbac.Role)),
    project: String,
    environment: String,
    retention_days: Int,
    relay_max_events: Int,
    relay_max_bytes: Int,
    enrollment_ttl_ms: Int,
    blob_backend: BlobBackendConfig,
  )
}

pub type BlobBackendConfig {
  FilesystemBlobs
  S3Blobs(endpoint: String, bucket: String, region: String, prefix: String)
}

pub type ConfigError {
  Missing(key: String)
  DistributionCookieForbidden
  ClientSecretForbidden
  BlobSecretForbidden
  InvalidUrl(key: String)
  RedirectOriginMismatch
  InvalidRoleMapping(value: String)
  InvalidInteger(key: String, value: String)
  InvalidValue(key: String)
  JwksReadFailed(path: String, reason: String)
}

pub fn load_environment() -> Result(Option(Config), ConfigError) {
  environment_pairs()
  |> dict.from_list
  |> load_if_requested_with(read_jwks_file)
}

pub fn load_if_requested_with(
  source: Dict(String, String),
  read_jwks: fn(String) -> Result(String, String),
) -> Result(Option(Config), ConfigError) {
  use Nil <- try_result(reject_forbidden(source))
  case dict.get(source, "team") {
    Error(_) -> Ok(None)
    Ok("false") | Ok("0") | Ok("no") -> Ok(None)
    Ok("true") | Ok("1") | Ok("yes") -> {
      use path <- try_result(required(source, "oidc_jwks_file"))
      use jwks <- try_result(case read_jwks(path) {
        Ok(contents) -> Ok(contents)
        Error(reason) -> Error(JwksReadFailed(path, reason))
      })
      resolve(dict.insert(source, "oidc_jwks_json", jwks))
      |> map_result(Some)
    }
    Ok(_) -> Error(InvalidValue("team"))
  }
}

pub fn resolve(source: Dict(String, String)) -> Result(Config, ConfigError) {
  use Nil <- try_result(reject_forbidden(source))
  use origin <- try_result(required(source, "origin"))
  use authorization_endpoint <- try_result(required(
    source,
    "oidc_authorization_endpoint",
  ))
  use token_endpoint <- try_result(required(source, "oidc_token_endpoint"))
  use issuer <- try_result(required(source, "oidc_issuer"))
  use client_id <- try_result(required(source, "oidc_client_id"))
  use redirect_uri <- try_result(required(source, "oidc_redirect_uri"))
  use jwks_json <- try_result(required(source, "oidc_jwks_json"))
  use group_roles_source <- try_result(required_present(
    source,
    "oidc_group_roles",
  ))
  use project <- try_result(required(source, "project"))
  use environment <- try_result(required(source, "environment"))

  use Nil <- try_result(validate_url("origin", origin, origin_only: True))
  use Nil <- try_result(validate_url(
    "oidc_authorization_endpoint",
    authorization_endpoint,
    origin_only: False,
  ))
  use Nil <- try_result(validate_url(
    "oidc_token_endpoint",
    token_endpoint,
    origin_only: False,
  ))
  use Nil <- try_result(validate_url("oidc_issuer", issuer, origin_only: False))
  use Nil <- try_result(validate_url(
    "oidc_redirect_uri",
    redirect_uri,
    origin_only: False,
  ))
  use Nil <- try_result(validate_redirect(origin, redirect_uri))
  use group_roles <- try_result(parse_group_roles(group_roles_source))
  use port <- try_result(positive_integer(source, "port", "4040", 65_535))
  use retention_days <- try_result(positive_integer(
    source,
    "retention_days",
    "7",
    3650,
  ))
  use relay_max_events <- try_result(positive_integer(
    source,
    "relay_max_events",
    "1000000",
    1_000_000_000,
  ))
  use relay_max_bytes <- try_result(positive_integer(
    source,
    "relay_max_bytes",
    "1073741824",
    1_000_000_000_000,
  ))
  use enrollment_ttl_ms <- try_result(positive_integer(
    source,
    "enrollment_ttl_ms",
    "600000",
    86_400_000,
  ))
  use blob_backend <- try_result(resolve_blob_backend(source))
  use Nil <- try_result(bounded("oidc_client_id", client_id, 512))
  use Nil <- try_result(bounded("oidc_jwks_json", jwks_json, 1_048_576))
  use Nil <- try_result(bounded("project", project, 256))
  use Nil <- try_result(bounded("environment", environment, 256))
  let data_dir = optional(source, "data_dir", "beamtrace-data")
  use Nil <- try_result(bounded("data_dir", data_dir, 4096))

  Ok(Config(
    bind: optional(source, "bind", "127.0.0.1"),
    data_dir: data_dir,
    port: port,
    origin: trim_trailing_slash(origin),
    authorization_endpoint: authorization_endpoint,
    token_endpoint: token_endpoint,
    issuer: issuer,
    client_id: client_id,
    redirect_uri: redirect_uri,
    jwks_json: jwks_json,
    group_roles: group_roles,
    project: project,
    environment: environment,
    retention_days: retention_days,
    relay_max_events: relay_max_events,
    relay_max_bytes: relay_max_bytes,
    enrollment_ttl_ms: enrollment_ttl_ms,
    blob_backend: blob_backend,
  ))
}

fn reject_forbidden(source: Dict(String, String)) -> Result(Nil, ConfigError) {
  case
    dict.has_key(source, "cookie") || dict.has_key(source, "cookie_file"),
    dict.has_key(source, "oidc_client_secret"),
    dict.has_key(source, "s3_access_key_id")
    || dict.has_key(source, "s3_secret_access_key")
    || dict.has_key(source, "s3_session_token")
  {
    True, _, _ -> Error(DistributionCookieForbidden)
    _, True, _ -> Error(ClientSecretForbidden)
    _, _, True -> Error(BlobSecretForbidden)
    False, False, False -> Ok(Nil)
  }
}

fn resolve_blob_backend(
  source: Dict(String, String),
) -> Result(BlobBackendConfig, ConfigError) {
  case optional(source, "blob_backend", "filesystem") {
    "filesystem" -> Ok(FilesystemBlobs)
    "s3" -> {
      use endpoint <- try_result(required(source, "s3_endpoint"))
      use bucket <- try_result(required(source, "s3_bucket"))
      let region = optional(source, "s3_region", "us-east-1")
      let prefix = optional(source, "s3_prefix", "beamtrace")
      use Nil <- try_result(validate_url(
        "s3_endpoint",
        endpoint,
        origin_only: True,
      ))
      let config = s3_blob.Config(endpoint, bucket, region, prefix)
      case s3_blob.valid_config(config) {
        True -> Ok(S3Blobs(endpoint, bucket, region, prefix))
        False -> Error(InvalidValue("s3"))
      }
    }
    _ -> Error(InvalidValue("blob_backend"))
  }
}

fn required(
  source: Dict(String, String),
  key: String,
) -> Result(String, ConfigError) {
  case dict.get(source, key) {
    Ok(value) if value != "" -> Ok(value)
    _ -> Error(Missing(key))
  }
}

fn required_present(
  source: Dict(String, String),
  key: String,
) -> Result(String, ConfigError) {
  case dict.get(source, key) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Missing(key))
  }
}

fn optional(
  source: Dict(String, String),
  key: String,
  default: String,
) -> String {
  case dict.get(source, key) {
    Ok(value) if value != "" -> value
    _ -> default
  }
}

fn validate_url(
  key: String,
  source: String,
  origin_only origin_only: Bool,
) -> Result(Nil, ConfigError) {
  let within_budget = string.byte_size(source) <= 4096
  case uri.parse(source) {
    Ok(parsed) ->
      case
        parsed.scheme,
        parsed.host,
        parsed.userinfo,
        parsed.query,
        parsed.fragment,
        within_budget,
        origin_only && parsed.path != "" && parsed.path != "/"
      {
        Some("https"), Some(host), None, None, None, True, False if host != "" ->
          Ok(Nil)
        _, _, _, _, _, _, _ -> Error(InvalidUrl(key))
      }
    Error(_) -> Error(InvalidUrl(key))
  }
}

fn validate_redirect(
  origin: String,
  redirect_uri: String,
) -> Result(Nil, ConfigError) {
  case redirect_uri == trim_trailing_slash(origin) <> "/auth/oidc/callback" {
    True -> Ok(Nil)
    False -> Error(RedirectOriginMismatch)
  }
}

fn parse_group_roles(
  source: String,
) -> Result(List(#(String, rbac.Role)), ConfigError) {
  case source {
    "" -> Error(InvalidRoleMapping(source))
    _ -> parse_mappings(string.split(source, ","), source, [], [])
  }
}

fn parse_mappings(
  mappings: List(String),
  original: String,
  groups: List(String),
  accumulator: List(#(String, rbac.Role)),
) -> Result(List(#(String, rbac.Role)), ConfigError) {
  case mappings {
    [] -> Ok(list.reverse(accumulator))
    [mapping, ..rest] ->
      case string.split(mapping, ":") {
        [group, role_source] if group != "" ->
          case parse_role(role_source), list.contains(groups, group) {
            Ok(role), False ->
              parse_mappings(rest, original, [group, ..groups], [
                #(group, role),
                ..accumulator
              ])
            _, _ -> Error(InvalidRoleMapping(original))
          }
        _ -> Error(InvalidRoleMapping(original))
      }
  }
}

fn parse_role(source: String) -> Result(rbac.Role, Nil) {
  case source {
    "admin" -> Ok(rbac.Admin)
    "investigator" -> Ok(rbac.Investigator)
    "viewer" -> Ok(rbac.Viewer)
    "raw" -> Ok(rbac.RawCaptureRole)
    _ -> Error(Nil)
  }
}

fn positive_integer(
  source: Dict(String, String),
  key: String,
  default: String,
  maximum: Int,
) -> Result(Int, ConfigError) {
  let value = optional(source, key, default)
  case int.parse(value) {
    Ok(parsed) if parsed > 0 && parsed <= maximum -> Ok(parsed)
    _ -> Error(InvalidInteger(key, value))
  }
}

fn bounded(
  key: String,
  value: String,
  maximum: Int,
) -> Result(Nil, ConfigError) {
  case value != "" && string.byte_size(value) <= maximum {
    True -> Ok(Nil)
    False -> Error(InvalidValue(key))
  }
}

fn trim_trailing_slash(source: String) -> String {
  case string.ends_with(source, "/") {
    True -> trim_trailing_slash(string.drop_end(source, 1))
    False -> source
  }
}

fn try_result(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn map_result(result: Result(a, e), transform: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(transform(value))
    Error(error) -> Error(error)
  }
}

@external(erlang, "beamtrace_team_config_ffi", "environment_pairs")
fn environment_pairs() -> List(#(String, String))

@external(erlang, "beamtrace_team_config_ffi", "read_jwks_file")
fn read_jwks_file(path: String) -> Result(String, String)
