// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

pub type VerificationError {
  Malformed
  UnsupportedAlgorithm
  UnknownKey
  InvalidSignature
  InvalidIssuer
  InvalidAudience
  NonceMismatch
  Expired
  NotYetValid
  InvalidSubject
}

pub opaque type VerifiedClaims {
  VerifiedClaims(subject: String, nonce: String, groups: List(String))
}

pub fn subject(claims: VerifiedClaims) -> String {
  claims.subject
}

pub fn nonce(claims: VerifiedClaims) -> String {
  claims.nonce
}

pub fn groups(claims: VerifiedClaims) -> List(String) {
  claims.groups
}

type Header {
  Header(algorithm: String, key_id: String, token_type: String)
}

type Claims {
  Claims(
    issuer: String,
    audiences: List(String),
    authorized_party: String,
    subject: String,
    nonce: String,
    expires_at: Int,
    issued_at: Int,
    not_before: Int,
    groups: List(String),
  )
}

type Jwk {
  Jwk(
    key_type: String,
    key_id: String,
    usage: String,
    algorithm: String,
    modulus: String,
    exponent: String,
    has_private_material: Bool,
  )
}

type Jwks {
  Jwks(keys: List(Jwk))
}

pub fn verify(
  token: String,
  jwks_json: String,
  issuer issuer: String,
  audience audience: String,
  expected_nonce expected_nonce: String,
  now_seconds now_seconds: Int,
) -> Result(VerifiedClaims, VerificationError) {
  case token_parts(token) {
    Error(_) -> Error(Malformed)
    Ok(parts) ->
      verify_decoded(
        token,
        parts,
        jwks_json,
        issuer,
        audience,
        expected_nonce,
        now_seconds,
      )
  }
}

/// Verify with at most one signing-key refresh, and only when the token's
/// `kid` is unknown. Signature or claim failures never trigger network work.
pub fn verify_with_refresh(
  token: String,
  jwks_json: String,
  issuer issuer: String,
  audience audience: String,
  expected_nonce expected_nonce: String,
  now_seconds now_seconds: Int,
  refresh refresh: fn() -> Result(String, String),
) -> Result(VerifiedClaims, VerificationError) {
  case verify(token, jwks_json, issuer, audience, expected_nonce, now_seconds) {
    Error(UnknownKey) ->
      case refresh() {
        Error(_) -> Error(UnknownKey)
        Ok(refreshed) ->
          verify(
            token,
            refreshed,
            issuer,
            audience,
            expected_nonce,
            now_seconds,
          )
      }
    result -> result
  }
}

/// Validate that a JWKS contains at least one RS256 public signing key and no
/// private key material on any accepted signing key.
pub fn validate_signing_jwks(source: String) -> Result(Nil, VerificationError) {
  case json.parse(source, jwks_decoder()) {
    Error(_) -> Error(Malformed)
    Ok(keys) ->
      case keys.keys {
        [] -> Error(UnknownKey)
        signing_keys ->
          case list.all(signing_keys, valid_signing_key) {
            True -> Ok(Nil)
            False -> Error(UnknownKey)
          }
      }
  }
}

fn verify_decoded(
  token: String,
  parts: #(String, String),
  jwks_json: String,
  issuer: String,
  audience: String,
  expected_nonce: String,
  now_seconds: Int,
) -> Result(VerifiedClaims, VerificationError) {
  case
    json.parse(parts.0, header_decoder()),
    json.parse(parts.1, claims_decoder()),
    json.parse(jwks_json, jwks_decoder())
  {
    Ok(header), Ok(claims), Ok(keys) ->
      verify_parsed(
        token,
        header,
        claims,
        keys,
        issuer,
        audience,
        expected_nonce,
        now_seconds,
      )
    _, _, _ -> Error(Malformed)
  }
}

fn verify_parsed(
  token: String,
  header: Header,
  claims: Claims,
  keys: Jwks,
  issuer: String,
  audience: String,
  expected_nonce: String,
  now_seconds: Int,
) -> Result(VerifiedClaims, VerificationError) {
  case
    header.algorithm == "RS256",
    header.token_type == "" || header.token_type == "JWT"
  {
    False, _ | _, False -> Error(UnsupportedAlgorithm)
    True, True ->
      case select_key(keys.keys, header.key_id) {
        Error(_) -> Error(UnknownKey)
        Ok(key) ->
          case verify_rs256(token, key.modulus, key.exponent) {
            False -> Error(InvalidSignature)
            True ->
              validate_claims(
                claims,
                issuer,
                audience,
                expected_nonce,
                now_seconds,
              )
          }
      }
  }
}

fn select_key(keys: List(Jwk), key_id: String) -> Result(Jwk, Nil) {
  list.find(keys, fn(key) {
    key.key_id == key_id && key_id != "" && valid_signing_key(key)
  })
}

fn valid_signing_key(key: Jwk) -> Bool {
  key.key_type == "RSA"
  && key.usage == "sig"
  && key.algorithm == "RS256"
  && key.modulus != ""
  && key.exponent != ""
  && !key.has_private_material
}

fn validate_claims(
  claims: Claims,
  issuer: String,
  audience: String,
  expected_nonce: String,
  now_seconds: Int,
) -> Result(VerifiedClaims, VerificationError) {
  let multiple_audiences = list.length(claims.audiences) > 1
  let audience_matches =
    list.contains(claims.audiences, audience)
    && { !multiple_audiences || claims.authorized_party == audience }
  case
    claims.issuer == issuer,
    audience_matches,
    claims.nonce == expected_nonce,
    now_seconds > claims.expires_at,
    claims.issued_at > now_seconds + 60
    || claims.not_before > now_seconds + 60
    || claims.expires_at <= claims.issued_at,
    string.trim(claims.subject) == ""
  {
    False, _, _, _, _, _ -> Error(InvalidIssuer)
    _, False, _, _, _, _ -> Error(InvalidAudience)
    _, _, False, _, _, _ -> Error(NonceMismatch)
    _, _, _, True, _, _ -> Error(Expired)
    _, _, _, _, True, _ -> Error(NotYetValid)
    _, _, _, _, _, True -> Error(InvalidSubject)
    True, True, True, False, False, False ->
      Ok(VerifiedClaims(claims.subject, claims.nonce, claims.groups))
  }
}

fn header_decoder() -> decode.Decoder(Header) {
  use algorithm <- decode.field("alg", decode.string)
  use key_id <- decode.field("kid", decode.string)
  use token_type <- decode.optional_field("typ", "", decode.string)
  decode.success(Header(algorithm, key_id, token_type))
}

fn claims_decoder() -> decode.Decoder(Claims) {
  use issuer <- decode.field("iss", decode.string)
  use audiences <- decode.field("aud", audience_decoder())
  use authorized_party <- decode.optional_field("azp", "", decode.string)
  use subject <- decode.field("sub", decode.string)
  use nonce <- decode.field("nonce", decode.string)
  use expires_at <- decode.field("exp", decode.int)
  use issued_at <- decode.field("iat", decode.int)
  use not_before <- decode.optional_field("nbf", 0, decode.int)
  use groups <- decode.optional_field("groups", [], decode.list(decode.string))
  decode.success(Claims(
    issuer,
    audiences,
    authorized_party,
    subject,
    nonce,
    expires_at,
    issued_at,
    not_before,
    groups,
  ))
}

fn audience_decoder() -> decode.Decoder(List(String)) {
  decode.one_of(decode.string |> decode.map(fn(value) { [value] }), or: [
    decode.list(decode.string),
  ])
}

fn jwks_decoder() -> decode.Decoder(Jwks) {
  use keys <- decode.field("keys", decode.list(jwk_decoder()))
  decode.success(Jwks(keys))
}

fn jwk_decoder() -> decode.Decoder(Jwk) {
  use key_type <- decode.field("kty", decode.string)
  use key_id <- decode.field("kid", decode.string)
  use use_ <- decode.optional_field("use", "", decode.string)
  use algorithm <- decode.optional_field("alg", "", decode.string)
  use modulus <- decode.field("n", decode.string)
  use exponent <- decode.field("e", decode.string)
  use d <- decode.optional_field("d", "", decode.string)
  use p <- decode.optional_field("p", "", decode.string)
  use q <- decode.optional_field("q", "", decode.string)
  use dp <- decode.optional_field("dp", "", decode.string)
  use dq <- decode.optional_field("dq", "", decode.string)
  use qi <- decode.optional_field("qi", "", decode.string)
  use symmetric_key <- decode.optional_field("k", "", decode.string)
  decode.success(Jwk(
    key_type,
    key_id,
    use_,
    algorithm,
    modulus,
    exponent,
    d != ""
      || p != ""
      || q != ""
      || dp != ""
      || dq != ""
      || qi != ""
      || symmetric_key != "",
  ))
}

@external(erlang, "beamtrace_id_token_ffi", "parts")
fn token_parts(token: String) -> Result(#(String, String), String)

@external(erlang, "beamtrace_id_token_ffi", "verify_rs256")
fn verify_rs256(token: String, modulus: String, exponent: String) -> Bool
