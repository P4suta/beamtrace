// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/oidc_discovery
import gleam/string
import gleeunit/should
import v2_fixture

const issuer = "https://id.example/tenant"

const metadata_url = "https://id.example/tenant/.well-known/openid-configuration"

const jwks_url = "https://id.example/tenant/jwks"

fn metadata(returned_issuer: String, authorization: String, jwks: String) {
  "{\"issuer\":\""
  <> returned_issuer
  <> "\",\"authorization_endpoint\":\""
  <> authorization
  <> "\",\"token_endpoint\":\"https://id.example/token\",\"jwks_uri\":\""
  <> jwks
  <> "\",\"id_token_signing_alg_values_supported\":[\"RS256\"]}"
}

fn successful_fetch(url: String, _maximum: Int) {
  case url == metadata_url, url == jwks_url {
    True, _ ->
      Ok(#(
        200,
        metadata(
          issuer,
          "https://id.example/authorize?tenant=beamtrace",
          jwks_url,
        ),
      ))
    _, True -> Ok(#(200, v2_fixture.public_jwks))
    False, False -> Error("unexpected_url")
  }
}

pub fn discovery_fetches_path_issuer_metadata_and_public_signing_keys_test() {
  let assert Ok(provider) =
    oidc_discovery.discover_with(issuer, successful_fetch)
  provider.issuer |> should.equal(issuer)
  provider.authorization_endpoint
  |> should.equal("https://id.example/authorize?tenant=beamtrace")
  provider.jwks_json |> should.equal(v2_fixture.public_jwks)
}

pub fn discovery_requires_exact_returned_issuer_test() {
  oidc_discovery.discover_with(issuer, fn(url, _) {
    case url == metadata_url {
      True ->
        Ok(#(200, metadata(issuer <> "/", "https://id.example/auth", jwks_url)))
      False -> Ok(#(200, v2_fixture.public_jwks))
    }
  })
  |> should.equal(Error(oidc_discovery.IssuerMismatch))
}

pub fn discovery_rejects_http_redirect_oversize_and_private_jwks_test() {
  oidc_discovery.discover_with("http://id.example", successful_fetch)
  |> should.equal(Error(oidc_discovery.InvalidIssuer))

  oidc_discovery.discover_with(issuer, fn(_, _) { Ok(#(302, "redirect")) })
  |> should.equal(Error(oidc_discovery.UnexpectedStatus(302)))

  oidc_discovery.discover_with(issuer, fn(_, maximum) {
    Ok(#(200, string.repeat("x", maximum + 1)))
  })
  |> should.equal(Error(oidc_discovery.ResponseTooLarge))

  oidc_discovery.discover_with(issuer, fn(url, _) {
    case url == metadata_url {
      True -> Ok(#(200, metadata(issuer, "https://id.example/auth", jwks_url)))
      False ->
        Ok(#(
          200,
          string.replace(
            v2_fixture.public_jwks,
            "\"e\":\"Aw\"",
            "\"e\":\"Aw\",\"d\":\"private\"",
          ),
        ))
    }
  })
  |> should.equal(Error(oidc_discovery.InvalidJwks))

  oidc_discovery.discover_with(issuer, fn(url, _) {
    case url == metadata_url {
      True -> Ok(#(200, metadata(issuer, "https://id.example/auth", jwks_url)))
      False ->
        Ok(#(
          200,
          string.drop_end(v2_fixture.public_jwks, 2)
            <> ",{\"kty\":\"RSA\",\"kid\":\"private\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"AQ\",\"e\":\"Aw\",\"d\":\"secret\"}]}",
        ))
    }
  })
  |> should.equal(Error(oidc_discovery.InvalidJwks))
}
