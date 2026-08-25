// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_client
import beamtrace_runtime/relay_payload
import beamtrace_runtime/relay_session
import beamtrace_runtime/relay_wire
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn enrollment_request_requires_https_and_contains_no_private_key_test() {
  let identity = relay_channel.new_identity()
  let assert Ok(request) =
    relay_client.prepare_enrollment(
      "https://hub.example/beamtrace/",
      "one-time-token",
      identity,
    )

  request.url
  |> should.equal("https://hub.example/beamtrace/api/relay/v1/enroll")
  request.body |> string.contains("one-time-token") |> should.be_true()
  request.body
  |> string.contains(bit_array.base64_url_encode(identity.public_key, False))
  |> should.be_true()
  request.body
  |> string.contains(bit_array.base64_url_encode(identity.private_key, False))
  |> should.be_false()

  relay_client.prepare_enrollment("http://hub.example", "token", identity)
  |> should.equal(Error(relay_client.InsecureHubUrl))
}

pub fn enrollment_url_rejects_credentials_query_and_fragment_test() {
  let identity = relay_channel.new_identity()
  [
    "https://user:pass@hub.example",
    "https://hub.example?token=leak",
    "https://hub.example#fragment",
    "not a url",
  ]
  |> list.each(fn(url) {
    relay_client.prepare_enrollment(url, "token", identity)
    |> should.equal(Error(relay_client.InvalidHubUrl))
  })
}

pub fn enrollment_response_requires_wss_channel_test() {
  relay_client.decode_receipt(
    "{\"relay_id\":\"relay-aabbccddeeff001122334455\",\"channel_url\":\"wss://hub.example/api/relay/v1/channel/relay-aabbccddeeff001122334455\"}",
  )
  |> should.equal(
    Ok(relay_client.EnrollmentReceipt(
      "relay-aabbccddeeff001122334455",
      "wss://hub.example/api/relay/v1/channel/relay-aabbccddeeff001122334455",
    )),
  )

  relay_client.decode_receipt(
    "{\"relay_id\":\"relay-aabbccddeeff001122334455\",\"channel_url\":\"ws://hub.example/channel\"}",
  )
  |> should.equal(
    Error(relay_client.InvalidResponse("channel_url must use wss")),
  )

  relay_client.decode_receipt(
    "{\"relay_id\":\"relay-aabbccddeeff001122334455\",\"channel_url\":\"wss://hub.example/channel?token=leak\"}",
  )
  |> should.equal(
    Error(relay_client.InvalidResponse("channel_url must use wss")),
  )
}

pub fn relay_channel_waits_for_credit_and_signs_strict_heartbeats_test() {
  let identity = relay_channel.new_identity()
  let initial = relay_client.initial_channel_state()
  let assert Ok(active) =
    relay_client.receive_control(
      initial,
      "{\"type\":\"credit\",\"protocol_version\":3,\"credits\":8,\"max_batch_events\":128}",
    )
  active
  |> should.equal(relay_client.Active(
    sequence: 0,
    credits: 8,
    max_batch_events: 128,
  ))

  let assert Ok(output) = relay_client.next_heartbeat(active, identity)
  let #(frame, next) = output
  next
  |> should.equal(relay_client.Active(
    sequence: 1,
    credits: 8,
    max_batch_events: 128,
  ))
  let assert Ok(envelope) = relay_wire.decode_envelope(frame)
  relay_wire.verify_envelope(identity.public_key, envelope, 0)
  |> should.equal(Ok("{\"type\":\"heartbeat\"}"))

  relay_client.receive_control(
    next,
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"hub_inbox_budget\"}",
  )
  |> should.equal(Ok(relay_client.Stopped("partial:hub_inbox_budget")))
}

pub fn relay_channel_rejects_data_before_credit_and_unbounded_controls_test() {
  let identity = relay_channel.new_identity()
  relay_client.next_heartbeat(relay_client.initial_channel_state(), identity)
  |> should.equal(Error("awaiting_credit"))
  relay_client.receive_control(
    relay_client.initial_channel_state(),
    "{\"type\":\"credit\",\"protocol_version\":3,\"credits\":1000001,\"max_batch_events\":128}",
  )
  |> should.equal(Error("invalid_control"))
  relay_client.receive_control(
    relay_client.initial_channel_state(),
    string.repeat("x", 16_385),
  )
  |> should.equal(Error("control_frame_too_large"))
}

pub fn session_ack_is_versioned_and_must_match_the_durable_end_test() {
  let end =
    relay_session.End(
      session_id: session_id(),
      sequence: 3,
      ended_at_ms: 2000,
      delivery_status: relay_session.Delivered,
    )
  let frame =
    "{\"type\":\"session_ack\",\"protocol_version\":3,\"session_id\":\""
    <> end.session_id
    <> "\",\"sequence\":3,\"delivery_status\":\"delivered\"}"
  relay_client.receive_session_ack(frame, end) |> should.equal(Ok(True))
  relay_client.receive_session_ack(
    string.replace(frame, "\"sequence\":3", "\"sequence\":2"),
    end,
  )
  |> should.equal(Error("invalid_session_ack"))
  relay_client.receive_session_ack(
    string.replace(frame, "\"protocol_version\":3", "\"protocol_version\":1"),
    end,
  )
  |> should.equal(Error("invalid_session_ack"))
  relay_client.receive_session_ack(
    "{\"type\":\"credit\",\"protocol_version\":3,\"credits\":4,\"max_batch_events\":128}",
    end,
  )
  |> should.equal(Ok(False))
}

fn event(id: String, term: types.TermView) -> types.TraceEvent {
  types.TraceEvent(
    id: id,
    root_id: "root-1",
    node: "fixture@host",
    process: types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", "<0.1.0>"),
      logical: None,
      evidence: [],
    ),
    local_instant: types.LocalInstant(100, 1),
    kind: types.Exit(term),
    evidence: types.Exact,
  )
}

pub fn credited_client_sends_validated_signed_event_batches_test() {
  let identity = relay_channel.new_identity()
  let state = relay_client.Active(sequence: 4, credits: 1, max_batch_events: 2)
  let events = [event("one", types.Hidden), event("two", types.Hidden)]
  let assert Ok(#(frame, next)) =
    relay_client.next_event_batch(
      state,
      identity,
      session_id(),
      1,
      relay_channel.Exact,
      events,
    )
  next
  |> should.equal(relay_client.Active(
    sequence: 5,
    credits: 0,
    max_batch_events: 2,
  ))
  let assert Ok(envelope) = relay_wire.decode_envelope(frame)
  let assert Ok(payload) =
    relay_wire.verify_envelope(identity.public_key, envelope, 4)
  let assert Ok(relay_session.Batch(_, 1, _, decoded)) =
    relay_session.decode_message(payload)
  decoded.event_count |> should.equal(2)
  decoded.mode |> should.equal("exact")
}

pub fn event_batches_require_credit_bounds_and_metadata_safety_test() {
  let identity = relay_channel.new_identity()
  let safe = event("safe", types.Hidden)
  relay_client.next_event_batch(
    relay_client.initial_channel_state(),
    identity,
    session_id(),
    1,
    relay_channel.Live,
    [safe],
  )
  |> should.equal(Error("awaiting_credit"))
  relay_client.next_event_batch(
    relay_client.Active(0, 1, 1),
    identity,
    session_id(),
    1,
    relay_channel.Live,
    [safe, safe],
  )
  |> should.equal(Error("batch_event_limit"))
  relay_client.next_event_batch(
    relay_client.Active(0, 1, 1),
    identity,
    session_id(),
    1,
    relay_channel.Exact,
    [
      event(
        "unsafe",
        types.Scalar(
          "string",
          Some("SENTINEL-client-secret"),
          Some(string.repeat("a", 64)),
        ),
      ),
    ],
  )
  |> should.equal(Error("metadata_value_forbidden"))
}

pub fn credited_client_signs_raw_batches_only_with_the_granted_policy_test() {
  let identity = relay_channel.new_identity()
  let state = relay_client.Active(sequence: 8, credits: 1, max_batch_events: 1)
  let grant = string.repeat("A", 43)
  let policy = types.RawPolicy(["password"], 2, 64)
  let raw_event =
    event(
      "raw",
      types.Scalar("integer", Some("42"), Some(string.repeat("e", 64))),
    )
  let assert Ok(#(frame, next)) =
    relay_client.next_raw_event_batch(
      state,
      identity,
      session_id(),
      1,
      relay_channel.Exact,
      grant,
      policy,
      [raw_event],
    )
  next |> should.equal(relay_client.Active(9, 0, 1))
  let assert Ok(envelope) = relay_wire.decode_envelope(frame)
  let assert Ok(payload) =
    relay_wire.verify_envelope(identity.public_key, envelope, 8)
  let assert Ok(relay_session.Batch(_, 1, _, decoded)) =
    relay_session.decode_message(payload)
  let assert relay_payload.RawBatch(received, received_policy) = decoded.privacy
  received |> should.equal(grant)
  received_policy |> should.equal(policy)
}

pub fn relay_rejects_one_oversized_encoded_event_and_splits_multi_event_prefixes_test() {
  let identity = relay_channel.new_identity()
  let grant = string.repeat("A", 43)
  let policy = types.RawPolicy(["password"], 2, 400_000)
  let oversized =
    event(
      "oversized",
      types.BinaryMetadata(
        300_000,
        Some(string.repeat("\"", 300_000)),
        Some(string.repeat("f", 64)),
      ),
    )
  relay_client.next_raw_event_batch(
    relay_client.Active(0, 1, 128),
    identity,
    session_id(),
    1,
    relay_channel.Exact,
    grant,
    policy,
    [oversized],
  )
  |> should.equal(Error("frame_too_large"))

  let medium = fn(id) {
    event(
      id,
      types.BinaryMetadata(
        120_000,
        Some(string.repeat("\"", 120_000)),
        Some(string.repeat("e", 64)),
      ),
    )
  }
  let events = [medium("one"), medium("two"), medium("three")]
  let assert Ok(#(frame, next, remaining)) =
    relay_client.next_raw_event_prefix(
      relay_client.Active(0, 3, 128),
      identity,
      session_id(),
      1,
      relay_channel.Exact,
      grant,
      policy,
      events,
    )
  let assert Ok(envelope) = relay_wire.decode_envelope(frame)
  let assert Ok(payload) =
    relay_wire.verify_envelope(identity.public_key, envelope, 0)
  let assert Ok(relay_session.Batch(_, 1, _, decoded)) =
    relay_session.decode_message(payload)
  let sent_some = decoded.event_count > 0
  let left_some = decoded.event_count < 3
  sent_some |> should.be_true()
  left_some |> should.be_true()
  list.length(remaining) + decoded.event_count |> should.equal(3)
  let assert relay_client.Active(1, 2, 128) = next
}

fn session_id() -> String {
  "00112233445566778899aabbccddeeff"
}
