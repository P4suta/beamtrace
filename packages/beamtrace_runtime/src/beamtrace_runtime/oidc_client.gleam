// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/uri

const max_response_bytes = 65_536

pub type TokenRequest {
  TokenRequest(url: String, body: String)
}

pub type TokenError {
  InsecureEndpoint
  InvalidEndpoint
  InvalidParameter(name: String)
  TransportError(reason: String)
  UnexpectedStatus(status: Int)
  ResponseTooLarge
  MalformedResponse
}

type TokenResponse {
  TokenResponse(id_token: String)
}

pub fn prepare_token_request(
  endpoint: String,
  client_id: String,
  code: String,
  code_verifier: String,
  redirect_uri: String,
) -> Result(TokenRequest, TokenError) {
  use Nil <- try_result(validate_endpoint(endpoint))
  use Nil <- try_result(validate_parameter(
    "client_id",
    client_id,
    maximum_bytes: 1024,
  ))
  use Nil <- try_result(validate_parameter("code", code, maximum_bytes: 8192))
  use Nil <- try_result(validate_verifier(code_verifier))
  use Nil <- try_result(validate_redirect_uri(redirect_uri))
  Ok(TokenRequest(
    url: endpoint,
    body: form_body(client_id, code, redirect_uri, code_verifier),
  ))
}

pub fn exchange(
  endpoint: String,
  client_id: String,
  code: String,
  code_verifier: String,
  redirect_uri: String,
) -> Result(String, TokenError) {
  exchange_with(
    endpoint,
    client_id,
    code,
    code_verifier,
    redirect_uri,
    fn(request) { post_form(request.url, request.body) },
  )
}

pub fn exchange_with(
  endpoint: String,
  client_id: String,
  code: String,
  code_verifier: String,
  redirect_uri: String,
  transport: fn(TokenRequest) -> Result(#(Int, String), String),
) -> Result(String, TokenError) {
  use request <- try_result(prepare_token_request(
    endpoint,
    client_id,
    code,
    code_verifier,
    redirect_uri,
  ))
  case transport(request) {
    Error(reason) -> Error(TransportError(reason))
    Ok(#(status, _)) if status != 200 -> Error(UnexpectedStatus(status))
    Ok(#(_, body)) ->
      case string.byte_size(body) > max_response_bytes {
        True -> Error(ResponseTooLarge)
        False -> decode_id_token(body)
      }
  }
}

fn decode_id_token(body: String) -> Result(String, TokenError) {
  case json.parse(body, token_response_decoder()) {
    Ok(response) ->
      case
        response.id_token != ""
        && string.byte_size(response.id_token) <= max_response_bytes
      {
        True -> Ok(response.id_token)
        False -> Error(MalformedResponse)
      }
    _ -> Error(MalformedResponse)
  }
}

fn token_response_decoder() -> decode.Decoder(TokenResponse) {
  use token <- decode.field("id_token", decode.string)
  decode.success(TokenResponse(token))
}

fn validate_endpoint(endpoint: String) -> Result(Nil, TokenError) {
  case uri.parse(endpoint) {
    Error(_) -> Error(InvalidEndpoint)
    Ok(parsed) ->
      case
        parsed.scheme,
        parsed.host,
        parsed.userinfo,
        parsed.query,
        parsed.fragment
      {
        Some("http"), Some(_), None, None, None -> Error(InsecureEndpoint)
        Some("https"), Some(host), None, None, None if host != "" -> Ok(Nil)
        _, _, _, _, _ -> Error(InvalidEndpoint)
      }
  }
}

fn validate_redirect_uri(redirect_uri: String) -> Result(Nil, TokenError) {
  let within_budget = string.byte_size(redirect_uri) <= 4096
  case uri.parse(redirect_uri) {
    Ok(parsed) ->
      case parsed.scheme, parsed.host, parsed.userinfo, parsed.fragment {
        Some("https"), Some(host), None, None if host != "" && within_budget ->
          Ok(Nil)
        _, _, _, _ -> Error(InvalidParameter("redirect_uri"))
      }
    Error(_) -> Error(InvalidParameter("redirect_uri"))
  }
}

fn validate_parameter(
  name: String,
  value: String,
  maximum_bytes maximum_bytes: Int,
) -> Result(Nil, TokenError) {
  case value != "" && string.byte_size(value) <= maximum_bytes {
    True -> Ok(Nil)
    False -> Error(InvalidParameter(name))
  }
}

fn validate_verifier(verifier: String) -> Result(Nil, TokenError) {
  case valid_pkce_verifier(verifier) {
    True -> Ok(Nil)
    False -> Error(InvalidParameter("code_verifier"))
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

@external(erlang, "beamtrace_oidc_http_ffi", "form_body")
fn form_body(
  client_id: String,
  code: String,
  redirect_uri: String,
  code_verifier: String,
) -> String

@external(erlang, "beamtrace_oidc_http_ffi", "valid_pkce_verifier")
fn valid_pkce_verifier(value: String) -> Bool

@external(erlang, "beamtrace_oidc_http_ffi", "post_form")
fn post_form(url: String, body: String) -> Result(#(Int, String), String)
