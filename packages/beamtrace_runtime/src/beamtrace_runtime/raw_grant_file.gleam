// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/raw_grant
import gleam/bit_array
import gleam/dynamic/decode as dynamic_decode
import gleam/json
import gleam/list
import gleam/string

pub type GrantFile {
  GrantFile(
    grant: String,
    relay_id: String,
    expires_at_ms: Int,
    max_events: Int,
    max_bytes: Int,
    policy: types.RawPolicy,
  )
}

type EncodedPolicy {
  EncodedPolicy(
    redact_keys: List(String),
    max_depth: Int,
    max_binary_bytes: Int,
  )
}

type EncodedGrant {
  EncodedGrant(
    grant: String,
    relay_id: String,
    expires_at_ms: Int,
    max_events: Int,
    max_bytes: Int,
    policy: EncodedPolicy,
  )
}

pub fn load(path: String) -> Result(GrantFile, String) {
  case read_bounded(path) {
    Error(_) -> Error("invalid_raw_grant_file")
    Ok(source) -> decode(source)
  }
}

pub fn wait_load(path: String, timeout_ms: Int) -> Result(GrantFile, String) {
  case read_bounded_wait(path, timeout_ms) {
    Error(_) -> Error("invalid_raw_grant_file")
    Ok(source) -> decode(source)
  }
}

pub fn authorize_for_relay(
  grant: GrantFile,
  relay_id: String,
  now_ms: Int,
) -> Result(Nil, String) {
  case grant.relay_id == relay_id, now_ms < grant.expires_at_ms {
    False, _ -> Error("raw_grant_relay_mismatch")
    True, False -> Error("raw_grant_expired")
    True, True -> Ok(Nil)
  }
}

pub fn decode(source: String) -> Result(GrantFile, String) {
  case string.byte_size(source) <= 16_384, json.parse(source, grant_decoder()) {
    True, Ok(encoded) -> {
      let policy =
        types.RawPolicy(
          encoded.policy.redact_keys,
          encoded.policy.max_depth,
          encoded.policy.max_binary_bytes,
        )
      let normalized = raw_grant.normalize_policy(policy)
      case
        raw_grant.valid_token(encoded.grant),
        valid_relay_id(encoded.relay_id),
        encoded.expires_at_ms > 0,
        encoded.max_events > 0 && encoded.max_events <= raw_grant.max_events,
        encoded.max_bytes > 0 && encoded.max_bytes <= raw_grant.max_bytes,
        normalized == policy,
        valid_policy(policy)
      {
        True, True, True, True, True, True, True ->
          Ok(GrantFile(
            encoded.grant,
            encoded.relay_id,
            encoded.expires_at_ms,
            encoded.max_events,
            encoded.max_bytes,
            policy,
          ))
        _, _, _, _, _, _, _ -> Error("invalid_raw_grant_file")
      }
    }
    _, _ -> Error("invalid_raw_grant_file")
  }
}

fn valid_policy(policy: types.RawPolicy) -> Bool {
  policy.redact_keys != []
  && list.length(policy.redact_keys) <= 128
  && list.all(policy.redact_keys, fn(key) {
    let bytes = string.byte_size(key)
    bytes > 0
    && bytes <= 128
    && !string.contains(key, "\u{0}")
    && !string.contains(key, "\n")
    && !string.contains(key, "\r")
  })
  && policy.max_depth > 0
  && policy.max_depth <= 32
  && policy.max_binary_bytes > 0
  && policy.max_binary_bytes <= 1_048_576
}

fn valid_relay_id(relay_id: String) -> Bool {
  case string.starts_with(relay_id, "relay-") {
    False -> False
    True -> {
      let suffix = string.drop_start(relay_id, 6)
      case bit_array.base16_decode(suffix) {
        Ok(bytes) ->
          bit_array.byte_size(bytes) == 12 && string.lowercase(suffix) == suffix
        Error(_) -> False
      }
    }
  }
}

fn grant_decoder() -> dynamic_decode.Decoder(EncodedGrant) {
  use grant <- dynamic_decode.field("grant", dynamic_decode.string)
  use relay_id <- dynamic_decode.field("relay_id", dynamic_decode.string)
  use expires_at_ms <- dynamic_decode.field("expires_at_ms", dynamic_decode.int)
  use max_events <- dynamic_decode.field("max_events", dynamic_decode.int)
  use max_bytes <- dynamic_decode.field("max_bytes", dynamic_decode.int)
  use policy <- dynamic_decode.field("policy", policy_decoder())
  dynamic_decode.success(EncodedGrant(
    grant,
    relay_id,
    expires_at_ms,
    max_events,
    max_bytes,
    policy,
  ))
}

fn policy_decoder() -> dynamic_decode.Decoder(EncodedPolicy) {
  use redact_keys <- dynamic_decode.field(
    "redact_keys",
    dynamic_decode.list(dynamic_decode.string),
  )
  use max_depth <- dynamic_decode.field("max_depth", dynamic_decode.int)
  use max_binary_bytes <- dynamic_decode.field(
    "max_binary_bytes",
    dynamic_decode.int,
  )
  dynamic_decode.success(EncodedPolicy(redact_keys, max_depth, max_binary_bytes))
}

@external(erlang, "beamtrace_raw_grant_file_ffi", "read_bounded")
fn read_bounded(path: String) -> Result(String, String)

@external(erlang, "beamtrace_raw_grant_file_ffi", "read_bounded_wait")
fn read_bounded_wait(path: String, timeout_ms: Int) -> Result(String, String)
