// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/crypto
import beamtrace_runtime/team_store
import gleam/json
import gleam/list
import gleam/string

pub type IssuedGrant {
  IssuedGrant(
    token: String,
    relay_id: String,
    expires_at_ms: Int,
    max_events: Int,
    max_bytes: Int,
    policy: types.RawPolicy,
  )
}

pub const max_duration_ms = 30_000

pub const max_events = 100_000

pub const max_bytes = 64_000_000

pub fn issue(
  store: team_store.Store,
  relay_id relay_id: String,
  actor actor: String,
  now_ms now_ms: Int,
  duration_ms duration_ms: Int,
  max_events requested_events: Int,
  max_bytes requested_bytes: Int,
  policy requested_policy: types.RawPolicy,
) -> Result(IssuedGrant, String) {
  let policy = normalize_policy(requested_policy)
  case
    now_ms >= 0,
    duration_ms > 0 && duration_ms <= max_duration_ms,
    requested_events > 0 && requested_events <= max_events,
    requested_bytes > 0 && requested_bytes <= max_bytes,
    valid_policy(policy)
  {
    True, True, True, True, True -> {
      let token = crypto.random_base64url(32)
      let expires_at_ms = now_ms + duration_ms
      let grant =
        team_store.RawCaptureGrant(
          token_hash: token_hash(token),
          relay_id: relay_id,
          actor: actor,
          created_at_ms: now_ms,
          expires_at_ms: expires_at_ms,
          max_events: requested_events,
          used_events: 0,
          max_bytes: requested_bytes,
          used_bytes: 0,
          policy_hash: policy_hash(policy),
          status: "active",
        )
      case team_store.put_raw_capture_grant(store, grant) {
        Error(_) -> Error("invalid_raw_capture_grant")
        Ok(Nil) ->
          Ok(IssuedGrant(
            token,
            relay_id,
            expires_at_ms,
            requested_events,
            requested_bytes,
            policy,
          ))
      }
    }
    _, _, _, _, _ -> Error("invalid_raw_capture_grant")
  }
}

pub fn reserve(
  store: team_store.Store,
  token: String,
  relay_id: String,
  policy: types.RawPolicy,
  events events: Int,
  bytes bytes: Int,
  now_ms now_ms: Int,
) -> Result(Nil, String) {
  team_store.reserve_raw_capture_grant(
    store,
    token_hash(token),
    relay_id,
    policy_hash(normalize_policy(policy)),
    events:,
    bytes:,
    now_ms:,
  )
}

pub fn normalize_policy(policy: types.RawPolicy) -> types.RawPolicy {
  types.RawPolicy(
    policy.redact_keys
      |> list.map(fn(key) { key |> string.trim |> string.lowercase })
      |> unique([], [])
      |> list.sort(string.compare),
    policy.max_depth,
    policy.max_binary_bytes,
  )
}

pub fn canonical_policy(policy: types.RawPolicy) -> String {
  let normalized = normalize_policy(policy)
  json.object([
    #("redact_keys", json.array(normalized.redact_keys, json.string)),
    #("max_depth", json.int(normalized.max_depth)),
    #("max_binary_bytes", json.int(normalized.max_binary_bytes)),
  ])
  |> json.to_string
}

pub fn policy_hash(policy: types.RawPolicy) -> String {
  crypto.sha256_hex(canonical_policy(policy))
}

pub fn token_hash(token: String) -> String {
  crypto.sha256_hex(token)
}

@external(erlang, "beamtrace_raw_grant_ffi", "valid_token")
pub fn valid_token(token: String) -> Bool

fn valid_policy(policy: types.RawPolicy) -> Bool {
  policy.redact_keys != []
  && list.length(policy.redact_keys) <= 128
  && list.all(policy.redact_keys, valid_redact_key)
  && policy.max_depth > 0
  && policy.max_depth <= 32
  && policy.max_binary_bytes > 0
  && policy.max_binary_bytes <= 1_048_576
}

fn valid_redact_key(key: String) -> Bool {
  let bytes = string.byte_size(key)
  bytes > 0
  && bytes <= 128
  && !string.contains(key, "\u{0}")
  && !string.contains(key, "\n")
  && !string.contains(key, "\r")
}

fn unique(
  remaining: List(String),
  seen: List(String),
  output: List(String),
) -> List(String) {
  case remaining {
    [] -> list.reverse(output)
    [key, ..rest] ->
      case list.contains(seen, key) {
        True -> unique(rest, seen, output)
        False -> unique(rest, [key, ..seen], [key, ..output])
      }
  }
}
