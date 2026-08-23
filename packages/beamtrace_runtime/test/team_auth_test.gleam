// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/oidc
import beamtrace_runtime/rbac
import beamtrace_runtime/team_auth
import gleeunit/should

pub fn team_sessions_require_a_validated_oidc_attempt_test() {
  let store = team_auth.new()
  let oidc.AuthorizationStart(attempt, verifier) =
    oidc.begin("https://hub.example/callback", 1000, 60_000)

  team_auth.issue_from_oidc(
    store,
    attempt,
    subject: "user-1",
    roles: [rbac.Viewer],
    project: "shop",
    environment: "prod",
    now_ms: 1001,
    ttl_ms: 100,
  )
  |> should.equal(Error(team_auth.OidcNotValidated))

  let assert Ok(validated) =
    oidc.validate(
      attempt,
      oidc.state(attempt),
      oidc.nonce(attempt),
      verifier,
      oidc.redirect_uri(attempt),
      1001,
      oidc.pkce_s256,
    )
  let assert Ok(session) =
    team_auth.issue_from_oidc(
      store,
      validated,
      "user-1",
      [rbac.Viewer],
      "shop",
      "prod",
      1001,
      100,
    )

  team_auth.authorize_at(store, session.id, 1101)
  |> should.equal(Ok(session))
  team_auth.authorize_at(store, session.id, 1102)
  |> should.equal(Error("expired"))
  team_auth.close(store)
}

pub fn team_session_tokens_are_random_capabilities_test() {
  let store = team_auth.new()
  let first = validated_attempt("first")
  let second = validated_attempt("second")
  let assert Ok(session) =
    team_auth.issue_from_oidc(
      store,
      first,
      "user-2",
      [rbac.Investigator],
      "shop",
      "staging",
      1000,
      100,
    )
  let assert Ok(other) =
    team_auth.issue_from_oidc(
      store,
      second,
      "user-2",
      [rbac.Investigator],
      "shop",
      "staging",
      1000,
      100,
    )
  should.be_false(session.id == other.id)
  should.be_false(session.csrf_token == other.csrf_token)
  team_auth.authorize_at(store, session.id <> "x", 1001)
  |> should.equal(Error("invalid_session"))
  team_auth.close(store)
}

fn validated_attempt(label: String) -> oidc.Attempt {
  let attempt =
    oidc.new(
      "state-" <> label,
      "nonce-" <> label,
      oidc.pkce_s256("verifier-" <> label),
      "https://hub.example/callback",
      2000,
    )
  let assert Ok(validated) =
    oidc.validate(
      attempt,
      oidc.state(attempt),
      oidc.nonce(attempt),
      "verifier-" <> label,
      oidc.redirect_uri(attempt),
      1000,
      oidc.pkce_s256,
    )
  validated
}
