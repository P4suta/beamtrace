// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/raw_grant_file
import gleam/int
import gleam/string
import gleeunit/should

fn receipt(grant: String, depth: Int) -> String {
  "{\"grant\":\""
  <> grant
  <> "\",\"relay_id\":\"relay-11223344556677889900aabb\","
  <> "\"expires_at_ms\":6000,\"max_events\":10,\"max_bytes\":4096,"
  <> "\"policy\":{\"redact_keys\":[\"password\",\"token\"],"
  <> "\"max_depth\":"
  <> int.to_string(depth)
  <> ",\"max_binary_bytes\":64}}"
}

pub fn authorization_receipt_decodes_to_the_exact_capture_policy_test() {
  let grant = string.repeat("A", 43)
  let assert Ok(decoded) = raw_grant_file.decode(receipt(grant, 4))
  decoded.grant |> should.equal(grant)
  decoded.relay_id |> should.equal("relay-11223344556677889900aabb")
  decoded.policy
  |> should.equal(types.RawPolicy(["password", "token"], 4, 64))
}

pub fn authorization_receipt_rejects_invalid_tokens_and_unbounded_policy_test() {
  raw_grant_file.decode(receipt("plaintext-token", 4))
  |> should.equal(Error("invalid_raw_grant_file"))
  raw_grant_file.decode(receipt(string.repeat("A", 43), 33))
  |> should.equal(Error("invalid_raw_grant_file"))
}

pub fn grant_file_must_match_the_enrolled_relay_and_still_be_live_test() {
  let assert Ok(decoded) =
    raw_grant_file.decode(receipt(string.repeat("A", 43), 4))
  raw_grant_file.authorize_for_relay(
    decoded,
    "relay-11223344556677889900aabb",
    5999,
  )
  |> should.equal(Ok(Nil))
  raw_grant_file.authorize_for_relay(
    decoded,
    "relay-ffffffffffffffffffffffff",
    5999,
  )
  |> should.equal(Error("raw_grant_relay_mismatch"))
  raw_grant_file.authorize_for_relay(
    decoded,
    "relay-11223344556677889900aabb",
    6000,
  )
  |> should.equal(Error("raw_grant_expired"))
}
