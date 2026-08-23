// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/raw_grant
import beamtrace_runtime/team_store
import gleam/option.{Some}
import gleam/string
import gleeunit/should

pub fn issue_normalizes_policy_and_persists_only_a_token_hash_test() {
  let assert Ok(store) = team_store.open(":memory:")
  let assert Ok(issued) =
    raw_grant.issue(
      store,
      relay_id: "relay-11223344556677889900aabb",
      actor: "investigator-1",
      now_ms: 1000,
      duration_ms: 5000,
      max_events: 10,
      max_bytes: 4096,
      policy: types.RawPolicy([" Token ", "password", "TOKEN"], 4, 128),
    )
  issued.policy.redact_keys |> should.equal(["password", "token"])
  issued.expires_at_ms |> should.equal(6000)
  let token_is_long_enough = string.byte_size(issued.token) >= 43
  token_is_long_enough |> should.be_true()

  let hash = raw_grant.token_hash(issued.token)
  let assert Ok(Some(saved)) = team_store.raw_capture_grant(store, hash)
  saved.token_hash |> should.equal(hash)
  let plaintext_was_persisted = saved.token_hash == issued.token
  plaintext_was_persisted |> should.be_false()
  saved.policy_hash
  |> should.equal(raw_grant.policy_hash(issued.policy))
  team_store.close(store) |> should.equal(Ok(Nil))
}

pub fn issue_rejects_unbounded_or_unsafe_raw_policy_test() {
  let assert Ok(store) = team_store.open(":memory:")
  raw_grant.issue(
    store,
    relay_id: "relay-11223344556677889900aabb",
    actor: "investigator-1",
    now_ms: 1000,
    duration_ms: 30_001,
    max_events: 10,
    max_bytes: 4096,
    policy: types.RawPolicy(["password"], 4, 128),
  )
  |> should.equal(Error("invalid_raw_capture_grant"))
  raw_grant.issue(
    store,
    relay_id: "relay-11223344556677889900aabb",
    actor: "investigator-1",
    now_ms: 1000,
    duration_ms: 1000,
    max_events: 10,
    max_bytes: 4096,
    policy: types.RawPolicy(["bad\nkey"], 4, 128),
  )
  |> should.equal(Error("invalid_raw_capture_grant"))
  team_store.close(store) |> should.equal(Ok(Nil))
}
