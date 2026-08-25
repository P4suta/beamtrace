// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/team_store
import gleam/list

pub type Store

pub type RelayRecord {
  RelayRecord(id: String, algorithm: String, public_key: BitArray)
}

@external(erlang, "beamtrace_enrollment_store_ffi", "new_at")
pub fn new_at(now_ms: Int, ttl_ms: Int) -> #(Store, String)

pub fn persistent_at(
  database: team_store.Store,
  now_ms: Int,
  ttl_ms: Int,
) -> Result(#(Store, String), String) {
  case team_store.relay_identities(database) {
    Error(reason) -> Error(reason)
    Ok(identities) -> {
      let relays =
        identities
        |> list.map(fn(identity) { #(identity.id, identity.public_key) })
      Ok(
        new_with_relays_at(now_ms, ttl_ms, relays, fn(id, key, enrolled_at) {
          team_store.put_relay_identity(
            database,
            team_store.RelayIdentity(id, "Ed25519", key, enrolled_at),
          )
        }),
      )
    }
  }
}

@external(erlang, "beamtrace_enrollment_store_ffi", "new_with_relays_at")
fn new_with_relays_at(
  now_ms: Int,
  ttl_ms: Int,
  relays: List(#(String, BitArray)),
  persist: fn(String, BitArray, Int) -> Result(Nil, String),
) -> #(Store, String)

@external(erlang, "beamtrace_enrollment_store_ffi", "consume")
pub fn consume(
  store: Store,
  code: String,
  public_key: BitArray,
  now_ms: Int,
) -> Result(RelayRecord, String)

@external(erlang, "beamtrace_enrollment_store_ffi", "authenticate")
pub fn authenticate(
  store: Store,
  protocol_version: Int,
  relay_id: String,
  timestamp_ms: Int,
  nonce: BitArray,
  signature: BitArray,
  now_ms: Int,
) -> Result(RelayRecord, String)

@external(erlang, "beamtrace_enrollment_store_ffi", "close")
pub fn close(store: Store) -> Nil
