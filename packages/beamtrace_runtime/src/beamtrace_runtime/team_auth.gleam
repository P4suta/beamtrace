// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/oidc
import beamtrace_runtime/rbac
import gleam/int

pub type Store

pub type Session {
  Session(
    id: String,
    csrf_token: String,
    subject: String,
    roles: List(rbac.Role),
    project: String,
    environment: String,
  )
}

pub type IssueError {
  OidcNotValidated
}

@external(erlang, "beamtrace_team_auth_ffi", "new")
pub fn new() -> Store

pub fn issue_from_oidc(
  store: Store,
  attempt: oidc.Attempt,
  subject subject: String,
  roles roles: List(rbac.Role),
  project project: String,
  environment environment: String,
  now_ms now_ms: Int,
  ttl_ms ttl_ms: Int,
) -> Result(Session, IssueError) {
  case oidc.is_validated(attempt) {
    False -> Error(OidcNotValidated)
    True ->
      Ok(issue(
        store,
        subject,
        roles,
        project,
        environment,
        now_ms,
        int.max(1, ttl_ms),
      ))
  }
}

@external(erlang, "beamtrace_team_auth_ffi", "issue")
fn issue(
  store: Store,
  subject: String,
  roles: List(rbac.Role),
  project: String,
  environment: String,
  now_ms: Int,
  ttl_ms: Int,
) -> Session

@external(erlang, "beamtrace_team_auth_ffi", "authorize_at")
pub fn authorize_at(
  store: Store,
  session_id: String,
  now_ms: Int,
) -> Result(Session, String)

@external(erlang, "beamtrace_team_auth_ffi", "close")
pub fn close(store: Store) -> Nil
