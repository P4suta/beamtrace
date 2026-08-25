// SPDX-License-Identifier: Apache-2.0 OR MIT

import beamtrace_runtime/crypto

pub opaque type Attempt {
  Attempt(
    state: String,
    nonce: String,
    code_challenge: String,
    redirect_uri: String,
    expires_at_ms: Int,
    used: Bool,
  )
}

pub fn state(attempt: Attempt) -> String {
  attempt.state
}

pub fn nonce(attempt: Attempt) -> String {
  attempt.nonce
}

pub fn code_challenge(attempt: Attempt) -> String {
  attempt.code_challenge
}

pub fn redirect_uri(attempt: Attempt) -> String {
  attempt.redirect_uri
}

pub fn expires_at_ms(attempt: Attempt) -> Int {
  attempt.expires_at_ms
}

pub fn is_validated(attempt: Attempt) -> Bool {
  attempt.used
}

pub type ValidationError {
  AlreadyUsed
  Expired
  StateMismatch
  NonceMismatch
  PkceMismatch
  RedirectMismatch
}

pub type AuthorizationStart {
  AuthorizationStart(attempt: Attempt, code_verifier: String)
}

pub fn begin(
  redirect_uri: String,
  now_ms: Int,
  ttl_ms: Int,
) -> AuthorizationStart {
  let state = crypto.random_base64url(32)
  let nonce = crypto.random_base64url(32)
  let verifier = crypto.random_base64url(32)
  AuthorizationStart(
    attempt: new(
      state,
      nonce,
      pkce_s256(verifier),
      redirect_uri,
      now_ms + maximum_one(ttl_ms),
    ),
    code_verifier: verifier,
  )
}

pub fn pkce_s256(verifier: String) -> String {
  crypto.sha256_base64url(verifier)
}

@external(erlang, "beamtrace_oidc_ffi", "authorization_url")
pub fn authorization_url(
  endpoint: String,
  client_id: String,
  redirect_uri: String,
  state: String,
  nonce: String,
  code_challenge: String,
) -> Result(String, String)

pub fn new(
  state state: String,
  nonce nonce: String,
  code_challenge code_challenge: String,
  redirect_uri redirect_uri: String,
  expires_at_ms expires_at_ms: Int,
) -> Attempt {
  Attempt(state, nonce, code_challenge, redirect_uri, expires_at_ms, False)
}

/// Validate the correlation fields before a team-mode session is created. The
/// challenge function is injected so the protocol logic remains deterministic
/// and the runtime can supply the audited SHA-256/base64url implementation.
pub fn validate(
  attempt: Attempt,
  presented_state presented_state: String,
  id_token_nonce id_token_nonce: String,
  code_verifier code_verifier: String,
  redirect_uri redirect_uri: String,
  now_ms now_ms: Int,
  challenge challenge: fn(String) -> String,
) -> Result(Attempt, ValidationError) {
  case
    attempt.used,
    now_ms > attempt.expires_at_ms,
    crypto.constant_time_equal_string(presented_state, attempt.state),
    crypto.constant_time_equal_string(id_token_nonce, attempt.nonce),
    redirect_uri == attempt.redirect_uri,
    crypto.constant_time_equal_string(
      challenge(code_verifier),
      attempt.code_challenge,
    )
  {
    True, _, _, _, _, _ -> Error(AlreadyUsed)
    _, True, _, _, _, _ -> Error(Expired)
    _, _, False, _, _, _ -> Error(StateMismatch)
    _, _, _, False, _, _ -> Error(NonceMismatch)
    _, _, _, _, False, _ -> Error(RedirectMismatch)
    _, _, _, _, _, False -> Error(PkceMismatch)
    False, False, True, True, True, True -> Ok(Attempt(..attempt, used: True))
  }
}

fn maximum_one(value: Int) -> Int {
  case value < 1 {
    True -> 1
    False -> value
  }
}
