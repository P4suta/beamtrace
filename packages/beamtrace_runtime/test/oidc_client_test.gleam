// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/oidc_client
import gleam/list
import gleam/string
import gleeunit/should

const verifier = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"

pub fn token_request_is_https_pkce_only_and_form_encoded_test() {
  let assert Ok(request) =
    oidc_client.prepare_token_request(
      "https://id.example/oauth/token",
      "beamtrace client",
      "code+&=/",
      verifier,
      "https://hub.example/auth/oidc/callback?tenant=a&region=jp",
    )

  request.url |> should.equal("https://id.example/oauth/token")
  request.body
  |> should.equal(
    "grant_type=authorization_code"
    <> "&client_id=beamtrace%20client"
    <> "&code=code%2B%26%3D%2F"
    <> "&redirect_uri=https%3A%2F%2Fhub.example%2Fauth%2Foidc%2Fcallback%3Ftenant%3Da%26region%3Djp"
    <> "&code_verifier="
    <> verifier,
  )
  request.body |> string.contains("client_secret") |> should.be_false()
}

pub fn token_request_rejects_untrusted_endpoints_and_invalid_pkce_test() {
  [
    "http://id.example/token",
    "https://user:pass@id.example/token",
    "https://id.example/token?next=evil",
    "https://id.example/token#fragment",
    "not-a-url",
  ]
  |> list.each(fn(endpoint) {
    oidc_client.prepare_token_request(
      endpoint,
      "client",
      "code",
      verifier,
      "https://hub.example/callback",
    )
    |> should.be_error()
  })

  oidc_client.prepare_token_request(
    "https://id.example/token",
    "client",
    "code",
    string.repeat("v", 42),
    "https://hub.example/callback",
  )
  |> should.equal(Error(oidc_client.InvalidParameter("code_verifier")))
  oidc_client.prepare_token_request(
    "https://id.example/token",
    "",
    "code",
    verifier,
    "https://hub.example/callback",
  )
  |> should.equal(Error(oidc_client.InvalidParameter("client_id")))
}

pub fn exchange_extracts_only_a_bounded_id_token_test() {
  oidc_client.exchange_with(
    "https://id.example/token",
    "client",
    "code",
    verifier,
    "https://hub.example/callback",
    fn(request) {
      request.url |> should.equal("https://id.example/token")
      request.body |> string.contains("code=code") |> should.be_true()
      Ok(#(
        200,
        "{\"access_token\":\"must-not-be-used\",\"token_type\":\"Bearer\",\"id_token\":\"signed.jwt.value\"}",
      ))
    },
  )
  |> should.equal(Ok("signed.jwt.value"))
}

pub fn exchange_rejects_redirects_transport_errors_and_oversized_json_test() {
  let exchange = fn(transport) {
    oidc_client.exchange_with(
      "https://id.example/token",
      "client",
      "code",
      verifier,
      "https://hub.example/callback",
      transport,
    )
  }

  exchange(fn(_) { Ok(#(302, "redirect")) })
  |> should.equal(Error(oidc_client.UnexpectedStatus(302)))
  exchange(fn(_) { Error("timeout") })
  |> should.equal(Error(oidc_client.TransportError("timeout")))
  exchange(fn(_) { Ok(#(200, string.repeat("x", 65_537))) })
  |> should.equal(Error(oidc_client.ResponseTooLarge))
  exchange(fn(_) { Ok(#(200, "{\"id_token\":\"\"}")) })
  |> should.equal(Error(oidc_client.MalformedResponse))
  exchange(fn(_) { Ok(#(200, "not-json")) })
  |> should.equal(Error(oidc_client.MalformedResponse))
}
