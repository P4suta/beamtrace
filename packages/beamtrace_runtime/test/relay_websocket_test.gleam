// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_session
import beamtrace_runtime/relay_websocket
import gleeunit/should

pub fn ingest_stop_frames_explain_budget_privacy_and_storage_failures_test() {
  relay_websocket.ingest_control_frame(
    Ok(relay_inbox.Truncated("frame_budget")),
  )
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"hub_inbox_budget\"}",
  )
  relay_websocket.ingest_control_frame(Error("relay_event_quota"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"hub_quota\"}",
  )
  relay_websocket.ingest_control_frame(Error("metadata_value_forbidden"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"privacy_policy\"}",
  )
  relay_websocket.ingest_control_frame(Error("raw_capture_grant_denied"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"privacy_policy\"}",
  )
  relay_websocket.ingest_control_frame(Error("raw_redaction_required"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"privacy_policy\"}",
  )
  relay_websocket.ingest_control_frame(Error("batch_event_limit"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"hub_quota\"}",
  )
  relay_websocket.ingest_control_frame(Error("session_event_quota"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"hub_quota\"}",
  )
  relay_websocket.ingest_control_frame(Error("session_relay_mismatch"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"relay_protocol\"}",
  )
  relay_websocket.ingest_control_frame(Error("invalid_payload"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"relay_protocol\"}",
  )
  relay_websocket.ingest_control_frame(Error("disk_full"))
  |> should.equal(
    "{\"type\":\"stop\",\"protocol_version\":3,\"delivery_status\":\"partial\",\"reason\":\"hub_storage_error\"}",
  )
}

pub fn completed_session_is_acknowledged_only_with_its_exact_identity_test() {
  relay_websocket.session_ack_frame(relay_session.End(
    session_id: "0123456789abcdef0123456789abcdef",
    sequence: 8,
    ended_at_ms: 9000,
    delivery_status: relay_session.Delivered,
  ))
  |> should.equal(
    "{\"type\":\"session_ack\",\"protocol_version\":3,\"session_id\":\"0123456789abcdef0123456789abcdef\",\"sequence\":8,\"delivery_status\":\"delivered\"}",
  )
}
