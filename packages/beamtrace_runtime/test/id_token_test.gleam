// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/id_token
import gleam/string
import gleeunit/should

pub type Fixture {
  Fixture(token: String, jwks: String)
}

@external(erlang, "beamtrace_id_token_test_ffi", "fixture")
fn fixture(
  algorithm: String,
  issuer: String,
  audience: String,
  nonce: String,
  now_seconds: Int,
) -> Fixture

pub fn valid_rs256_token_is_verified_against_pinned_claims_test() {
  let item =
    fixture("RS256", "https://id.example", "beamtrace", "nonce-1", 1000)
  let assert Ok(claims) =
    id_token.verify(
      item.token,
      item.jwks,
      issuer: "https://id.example",
      audience: "beamtrace",
      expected_nonce: "nonce-1",
      now_seconds: 1000,
    )
  id_token.subject(claims) |> should.equal("user-1")
  id_token.nonce(claims) |> should.equal("nonce-1")
  id_token.groups(claims) |> should.equal(["beamtrace-investigators"])
}

pub fn algorithm_confusion_unknown_key_and_signature_tampering_are_rejected_test() {
  let wrong_algorithm =
    fixture("HS256", "https://id.example", "beamtrace", "nonce-1", 1000)
  id_token.verify(
    wrong_algorithm.token,
    wrong_algorithm.jwks,
    "https://id.example",
    "beamtrace",
    "nonce-1",
    1000,
  )
  |> should.equal(Error(id_token.UnsupportedAlgorithm))

  let valid =
    fixture("RS256", "https://id.example", "beamtrace", "nonce-1", 1000)
  id_token.verify(
    valid.token,
    string.replace(valid.jwks, "key-1", "other-key"),
    "https://id.example",
    "beamtrace",
    "nonce-1",
    1000,
  )
  |> should.equal(Error(id_token.UnknownKey))
  id_token.verify(
    tamper(valid.token),
    valid.jwks,
    "https://id.example",
    "beamtrace",
    "nonce-1",
    1000,
  )
  |> should.equal(Error(id_token.InvalidSignature))
}

pub fn issuer_audience_nonce_and_time_claims_are_pinned_test() {
  let item =
    fixture("RS256", "https://id.example", "beamtrace", "nonce-1", 1000)
  id_token.verify(
    item.token,
    item.jwks,
    "https://other.example",
    "beamtrace",
    "nonce-1",
    1000,
  )
  |> should.equal(Error(id_token.InvalidIssuer))
  id_token.verify(
    item.token,
    item.jwks,
    "https://id.example",
    "other-client",
    "nonce-1",
    1000,
  )
  |> should.equal(Error(id_token.InvalidAudience))
  id_token.verify(
    item.token,
    item.jwks,
    "https://id.example",
    "beamtrace",
    "wrong-nonce",
    1000,
  )
  |> should.equal(Error(id_token.NonceMismatch))
  id_token.verify(
    item.token,
    item.jwks,
    "https://id.example",
    "beamtrace",
    "nonce-1",
    1301,
  )
  |> should.equal(Error(id_token.Expired))
}

pub fn malformed_or_oversized_tokens_are_rejected_before_crypto_test() {
  id_token.verify("not-a-jwt", "{\"keys\":[]}", "issuer", "aud", "nonce", 1)
  |> should.equal(Error(id_token.Malformed))
  id_token.verify(
    string.repeat("a", 65_537),
    "{\"keys\":[]}",
    "issuer",
    "aud",
    "nonce",
    1,
  )
  |> should.equal(Error(id_token.Malformed))
}

fn tamper(token: String) -> String {
  let assert [header, payload, signature] = string.split(token, ".")
  let replacement = case string.starts_with(signature, "A") {
    True -> "B"
    False -> "A"
  }
  header
  <> "."
  <> payload
  <> "."
  <> replacement
  <> string.drop_start(signature, 1)
}
