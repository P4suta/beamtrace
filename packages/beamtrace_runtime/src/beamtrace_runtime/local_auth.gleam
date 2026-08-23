// SPDX-License-Identifier: Apache-2.0 OR MIT

pub type Store

pub type Session {
  Session(id: String, csrf_token: String)
}

pub fn new(ttl_ms: Int) -> #(Store, String) {
  new_at(now_ms(), ttl_ms)
}

@external(erlang, "beamtrace_local_auth_ffi", "new_at")
pub fn new_at(now_ms: Int, ttl_ms: Int) -> #(Store, String)

@external(erlang, "beamtrace_local_auth_ffi", "exchange")
pub fn exchange(
  store: Store,
  token: String,
  now_ms: Int,
) -> Result(Session, String)

@external(erlang, "beamtrace_local_auth_ffi", "authorize")
pub fn authorize(store: Store, session_id: String) -> Bool

@external(erlang, "beamtrace_local_auth_ffi", "authorize_at")
pub fn authorize_at(store: Store, session_id: String, now_ms: Int) -> Bool

@external(erlang, "beamtrace_local_auth_ffi", "close")
pub fn close(store: Store) -> Nil

@external(erlang, "beamtrace_local_auth_ffi", "now_ms")
pub fn now_ms() -> Int
