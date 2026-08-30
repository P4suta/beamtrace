// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/id_token
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/uri

const maximum_metadata_bytes = 262_144

const maximum_jwks_bytes = 1_048_576

pub type ProviderMetadata {
  ProviderMetadata(
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    jwks_uri: String,
    jwks_json: String,
  )
}

pub type DiscoveryError {
  InvalidIssuer
  TransportFailed
  UnexpectedStatus(status: Int)
  ResponseTooLarge
  MalformedMetadata
  IssuerMismatch
  InvalidEndpoint(field: String)
  InvalidJwks
}

type MetadataDocument {
  MetadataDocument(
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    jwks_uri: String,
    signing_algorithms: List(String),
  )
}

/// Fetch and validate provider metadata and its public signing keys before a
/// Team listener is bound. Redirects are not followed by the production
/// transport and every response has a strict byte limit.
pub fn discover(issuer: String) -> Result(ProviderMetadata, DiscoveryError) {
  case discover_with(issuer, get_json) {
    Error(error) -> Error(error)
    Ok(provider) -> {
      remember_provider(provider.issuer, provider.jwks_uri, provider.jwks_json)
      Ok(provider)
    }
  }
}

/// Deterministic discovery boundary used by conformance tests.
pub fn discover_with(
  issuer: String,
  fetch: fn(String, Int) -> Result(#(Int, String), String),
) -> Result(ProviderMetadata, DiscoveryError) {
  use Nil <- try_result(
    validate_https_url(issuer, allow_query: False)
    |> map_error(fn(_) { InvalidIssuer }),
  )
  use metadata_url <- try_result(discovery_url(issuer))
  use metadata_body <- try_result(fetch_document(
    metadata_url,
    maximum_metadata_bytes,
    fetch,
  ))
  use metadata <- try_result(decode_metadata(metadata_body))
  use Nil <- try_result(case metadata.issuer == issuer {
    True -> Ok(Nil)
    False -> Error(IssuerMismatch)
  })
  use Nil <- try_result(validate_metadata_endpoints(metadata))
  use jwks <- try_result(fetch_document(
    metadata.jwks_uri,
    maximum_jwks_bytes,
    fetch,
  ))
  use Nil <- try_result(case id_token.validate_signing_jwks(jwks) {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> Error(InvalidJwks)
  })
  Ok(ProviderMetadata(
    issuer: metadata.issuer,
    authorization_endpoint: metadata.authorization_endpoint,
    token_endpoint: metadata.token_endpoint,
    jwks_uri: metadata.jwks_uri,
    jwks_json: jwks,
  ))
}

fn discovery_url(issuer: String) -> Result(String, DiscoveryError) {
  case uri.parse(issuer) {
    Error(_) -> Error(InvalidIssuer)
    Ok(parsed) -> {
      let issuer_path = trim_trailing_slashes(parsed.path)
      let discovery_path =
        case issuer_path {
          "" | "/" -> ""
          path -> path
        }
        <> "/.well-known/openid-configuration"
      Ok(
        uri.Uri(..parsed, path: discovery_path, query: None, fragment: None)
        |> uri.to_string,
      )
    }
  }
}

/// Return the latest cached keys for an issuer, or the configured offline
/// fallback when discovery is not active.
pub fn current_jwks(issuer: String, fallback: String) -> String {
  cached_jwks(issuer, fallback)
}

/// Refresh a discovered JWKS once. The returned set is validated before it is
/// cached; explicit/offline configurations have no refresh URI and fail.
pub fn refresh_jwks(issuer: String) -> Result(String, String) {
  case refresh_provider_jwks(issuer, maximum_jwks_bytes) {
    Error(error) -> Error(error)
    Ok(jwks) ->
      case id_token.validate_signing_jwks(jwks) {
        Error(_) -> Error("invalid_jwks")
        Ok(Nil) -> {
          cache_refreshed_jwks(issuer, jwks)
          Ok(jwks)
        }
      }
  }
}

fn fetch_document(
  url: String,
  maximum_bytes: Int,
  fetch: fn(String, Int) -> Result(#(Int, String), String),
) -> Result(String, DiscoveryError) {
  case fetch(url, maximum_bytes) {
    Error("response_too_large") -> Error(ResponseTooLarge)
    Error(_) -> Error(TransportFailed)
    Ok(#(status, _)) if status != 200 -> Error(UnexpectedStatus(status))
    Ok(#(_, body)) ->
      case string.byte_size(body) <= maximum_bytes {
        True -> Ok(body)
        False -> Error(ResponseTooLarge)
      }
  }
}

fn decode_metadata(source: String) -> Result(MetadataDocument, DiscoveryError) {
  case json.parse(source, metadata_decoder()) {
    Error(_) -> Error(MalformedMetadata)
    Ok(metadata) ->
      case
        metadata.issuer != "",
        metadata.authorization_endpoint != "",
        metadata.token_endpoint != "",
        metadata.jwks_uri != "",
        metadata.signing_algorithms == []
        || list_contains(metadata.signing_algorithms, "RS256")
      {
        True, True, True, True, True -> Ok(metadata)
        _, _, _, _, _ -> Error(MalformedMetadata)
      }
  }
}

fn metadata_decoder() -> decode.Decoder(MetadataDocument) {
  use issuer <- decode.field("issuer", decode.string)
  use authorization <- decode.field("authorization_endpoint", decode.string)
  use token <- decode.field("token_endpoint", decode.string)
  use jwks <- decode.field("jwks_uri", decode.string)
  use algorithms <- decode.optional_field(
    "id_token_signing_alg_values_supported",
    [],
    decode.list(decode.string),
  )
  decode.success(MetadataDocument(
    issuer,
    authorization,
    token,
    jwks,
    algorithms,
  ))
}

fn validate_metadata_endpoints(
  metadata: MetadataDocument,
) -> Result(Nil, DiscoveryError) {
  use Nil <- try_result(validate_endpoint(
    "authorization_endpoint",
    metadata.authorization_endpoint,
    True,
  ))
  use Nil <- try_result(validate_endpoint(
    "token_endpoint",
    metadata.token_endpoint,
    True,
  ))
  validate_endpoint("jwks_uri", metadata.jwks_uri, False)
}

fn validate_endpoint(
  field: String,
  value: String,
  allow_query: Bool,
) -> Result(Nil, DiscoveryError) {
  validate_https_url(value, allow_query)
  |> map_error(fn(_) { InvalidEndpoint(field) })
}

fn validate_https_url(
  value: String,
  allow_query allow_query: Bool,
) -> Result(Nil, Nil) {
  case string.byte_size(value) <= 4096, uri.parse(value) {
    True, Ok(parsed) ->
      case
        parsed.scheme,
        parsed.host,
        parsed.userinfo,
        parsed.fragment,
        allow_query || parsed.query == None
      {
        Some("https"), Some(host), None, None, True if host != "" -> Ok(Nil)
        _, _, _, _, _ -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

fn trim_trailing_slashes(source: String) -> String {
  case string.ends_with(source, "/") {
    True -> trim_trailing_slashes(string.drop_end(source, 1))
    False -> source
  }
}

fn list_contains(values: List(String), expected: String) -> Bool {
  case values {
    [] -> False
    [value, ..rest] -> value == expected || list_contains(rest, expected)
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

fn map_error(result: Result(a, e), transform: fn(e) -> f) -> Result(a, f) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(transform(error))
  }
}

@external(erlang, "beamtrace_oidc_discovery_ffi", "get_json")
fn get_json(url: String, maximum_bytes: Int) -> Result(#(Int, String), String)

@external(erlang, "beamtrace_oidc_discovery_ffi", "remember_provider")
fn remember_provider(issuer: String, jwks_uri: String, jwks: String) -> Nil

@external(erlang, "beamtrace_oidc_discovery_ffi", "cached_jwks")
fn cached_jwks(issuer: String, fallback: String) -> String

@external(erlang, "beamtrace_oidc_discovery_ffi", "refresh_jwks")
fn refresh_provider_jwks(
  issuer: String,
  maximum_bytes: Int,
) -> Result(String, String)

@external(erlang, "beamtrace_oidc_discovery_ffi", "cache_refreshed_jwks")
fn cache_refreshed_jwks(issuer: String, jwks: String) -> Nil
