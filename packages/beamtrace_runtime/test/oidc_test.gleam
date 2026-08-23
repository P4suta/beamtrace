// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/oidc
import gleam/string
import gleeunit/should

fn challenge(verifier: String) -> String {
  "S256:" <> verifier
}

pub fn oidc_callback_requires_state_nonce_pkce_redirect_and_single_use_test() {
  let attempt =
    oidc.new(
      state: "state-1",
      nonce: "nonce-1",
      code_challenge: "S256:verifier-1",
      redirect_uri: "https://hub.example/callback",
      expires_at_ms: 2000,
    )
  let assert Ok(validated) =
    oidc.validate(
      attempt,
      presented_state: "state-1",
      id_token_nonce: "nonce-1",
      code_verifier: "verifier-1",
      redirect_uri: "https://hub.example/callback",
      now_ms: 1000,
      challenge: challenge,
    )
  oidc.is_validated(validated) |> should.be_true()

  oidc.validate(
    validated,
    "state-1",
    "nonce-1",
    "verifier-1",
    "https://hub.example/callback",
    1001,
    challenge,
  )
  |> should.equal(Error(oidc.AlreadyUsed))
}

pub fn oidc_mismatch_errors_do_not_consume_attempt_test() {
  let attempt = oidc.new("s", "n", "S256:v", "https://hub/cb", 100)
  oidc.validate(attempt, "wrong", "n", "v", "https://hub/cb", 10, challenge)
  |> should.equal(Error(oidc.StateMismatch))
  oidc.is_validated(attempt) |> should.be_false()

  oidc.validate(attempt, "s", "wrong", "v", "https://hub/cb", 10, challenge)
  |> should.equal(Error(oidc.NonceMismatch))
  oidc.validate(attempt, "s", "n", "bad", "https://hub/cb", 10, challenge)
  |> should.equal(Error(oidc.PkceMismatch))
}

pub fn pkce_s256_matches_rfc7636_vector_test() {
  oidc.pkce_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  |> should.equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

pub fn secure_authorization_start_issues_distinct_correlation_secrets_test() {
  let first = oidc.begin("https://hub.example/callback", 1000, 60_000)
  let second = oidc.begin("https://hub.example/callback", 1000, 60_000)
  let state_is_distinct =
    oidc.state(first.attempt) != oidc.state(second.attempt)
  let nonce_is_distinct =
    oidc.nonce(first.attempt) != oidc.nonce(second.attempt)
  let verifier_is_distinct = first.code_verifier != second.code_verifier
  state_is_distinct |> should.be_true()
  nonce_is_distinct |> should.be_true()
  verifier_is_distinct |> should.be_true()
  oidc.code_challenge(first.attempt)
  |> should.equal(oidc.pkce_s256(first.code_verifier))
}

pub fn authorization_endpoint_requires_clean_https_and_encodes_values_test() {
  oidc.authorization_url(
    "http://id.example/authorize",
    "client",
    "https://hub.example/callback",
    "state",
    "nonce",
    "challenge",
  )
  |> should.equal(Error("invalid_authorization_endpoint"))
  oidc.authorization_url(
    "https://user@id.example/authorize",
    "client",
    "https://hub.example/callback",
    "state",
    "nonce",
    "challenge",
  )
  |> should.equal(Error("invalid_authorization_endpoint"))
  let assert Ok(url) =
    oidc.authorization_url(
      "https://id.example/authorize",
      "client id",
      "https://hub.example/callback?source=team",
      "state",
      "nonce",
      "challenge",
    )
  url
  |> string.contains("client_id=client%20id")
  |> should.be_true()
  url
  |> string.contains(
    "redirect_uri=https%3A%2F%2Fhub.example%2Fcallback%3Fsource%3Dteam",
  )
  |> should.be_true()
}
