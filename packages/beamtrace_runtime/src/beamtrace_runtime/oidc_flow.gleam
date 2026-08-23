// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/oidc

pub type Store

pub type Pending {
  Pending(attempt: oidc.Attempt, code_verifier: String)
}

@external(erlang, "beamtrace_oidc_flow_ffi", "new")
pub fn new() -> Store

pub fn remember(
  store: Store,
  start: oidc.AuthorizationStart,
) -> Result(Nil, String) {
  remember_record(
    store,
    oidc.state(start.attempt),
    start.attempt,
    start.code_verifier,
    oidc.expires_at_ms(start.attempt),
  )
}

@external(erlang, "beamtrace_oidc_flow_ffi", "remember")
fn remember_record(
  store: Store,
  state: String,
  attempt: oidc.Attempt,
  code_verifier: String,
  expires_at_ms: Int,
) -> Result(Nil, String)

@external(erlang, "beamtrace_oidc_flow_ffi", "consume")
pub fn consume(
  store: Store,
  state: String,
  now_ms: Int,
) -> Result(Pending, String)

@external(erlang, "beamtrace_oidc_flow_ffi", "close")
pub fn close(store: Store) -> Nil
