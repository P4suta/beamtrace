// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_client
import beamtrace_runtime/relay_payload
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
      "{\"type\":\"credit\",\"protocol_version\":1,\"credits\":8,\"max_batch_events\":128}",
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
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"hub_inbox_budget\"}",
  )
  |> should.equal(Ok(relay_client.Stopped("truncated:hub_inbox_budget")))
}

pub fn relay_channel_rejects_data_before_credit_and_unbounded_controls_test() {
  let identity = relay_channel.new_identity()
  relay_client.next_heartbeat(relay_client.initial_channel_state(), identity)
  |> should.equal(Error("awaiting_credit"))
  relay_client.receive_control(
    relay_client.initial_channel_state(),
    "{\"type\":\"credit\",\"protocol_version\":1,\"credits\":1000001,\"max_batch_events\":128}",
  )
  |> should.equal(Error("invalid_control"))
  relay_client.receive_control(
    relay_client.initial_channel_state(),
    string.repeat("x", 16_385),
  )
  |> should.equal(Error("control_frame_too_large"))
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
    local_timestamp_ns: 100,
    kind: types.Exit(term),
    evidence: types.Exact,
  )
}

pub fn credited_client_sends_validated_signed_event_batches_test() {
  let identity = relay_channel.new_identity()
  let state = relay_client.Active(sequence: 4, credits: 1, max_batch_events: 2)
  let events = [event("one", types.Hidden), event("two", types.Hidden)]
  let assert Ok(#(frame, next)) =
    relay_client.next_event_batch(state, identity, relay_channel.Exact, events)
  next
  |> should.equal(relay_client.Active(
    sequence: 5,
    credits: 0,
    max_batch_events: 2,
  ))
  let assert Ok(envelope) = relay_wire.decode_envelope(frame)
  let assert Ok(payload) =
    relay_wire.verify_envelope(identity.public_key, envelope, 4)
  let assert Ok(decoded) = relay_payload.decode(payload)
  decoded.event_count |> should.equal(2)
  decoded.mode |> should.equal("exact")
}

pub fn event_batches_require_credit_bounds_and_metadata_safety_test() {
  let identity = relay_channel.new_identity()
  let safe = event("safe", types.Hidden)
  relay_client.next_event_batch(
    relay_client.initial_channel_state(),
    identity,
    relay_channel.Live,
    [safe],
  )
  |> should.equal(Error("awaiting_credit"))
  relay_client.next_event_batch(
    relay_client.Active(0, 1, 1),
    identity,
    relay_channel.Live,
    [safe, safe],
  )
  |> should.equal(Error("batch_event_limit"))
  relay_client.next_event_batch(
    relay_client.Active(0, 1, 1),
    identity,
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
