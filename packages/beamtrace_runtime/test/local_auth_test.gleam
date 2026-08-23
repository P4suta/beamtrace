// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/local_auth
import gleeunit/should

pub fn bootstrap_token_is_single_use_and_becomes_session_capability_test() {
  let #(store, token) = local_auth.new_at(1000, 100)
  let assert Ok(session) = local_auth.exchange(store, token, 1050)
  local_auth.authorize_at(store, session.id, 1050) |> should.be_true()
  local_auth.authorize_at(store, "not-a-session", 1050) |> should.be_false()
  local_auth.exchange(store, token, 1051)
  |> should.equal(Error("already_used"))
  local_auth.close(store)
}

pub fn expired_or_incorrect_bootstrap_token_never_creates_session_test() {
  let #(expired_store, expired_token) = local_auth.new_at(1000, 10)
  local_auth.exchange(expired_store, expired_token, 1011)
  |> should.equal(Error("expired"))
  local_auth.close(expired_store)

  let #(store, _token) = local_auth.new_at(1000, 100)
  local_auth.exchange(store, "incorrect", 1001)
  |> should.equal(Error("invalid_token"))
  local_auth.close(store)
}
