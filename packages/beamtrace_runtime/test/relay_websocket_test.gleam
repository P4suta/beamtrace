// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_websocket
import gleeunit/should

pub fn durable_acceptance_replenishes_exactly_one_credit_test() {
  relay_websocket.ingest_control_frame(Ok(relay_inbox.Accepted))
  |> should.equal(
    "{\"type\":\"credit\",\"protocol_version\":1,\"credits\":1,\"max_batch_events\":128}",
  )
}

pub fn ingest_stop_frames_explain_budget_privacy_and_storage_failures_test() {
  relay_websocket.ingest_control_frame(
    Ok(relay_inbox.Truncated("frame_budget")),
  )
  |> should.equal(
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"hub_inbox_budget\"}",
  )
  relay_websocket.ingest_control_frame(Error("relay_event_quota"))
  |> should.equal(
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"hub_quota\"}",
  )
  relay_websocket.ingest_control_frame(Error("metadata_value_forbidden"))
  |> should.equal(
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"privacy_policy\"}",
  )
  relay_websocket.ingest_control_frame(Error("raw_capture_grant_denied"))
  |> should.equal(
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"privacy_policy\"}",
  )
  relay_websocket.ingest_control_frame(Error("raw_redaction_required"))
  |> should.equal(
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"privacy_policy\"}",
  )
  relay_websocket.ingest_control_frame(Error("batch_event_limit"))
  |> should.equal(
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"hub_quota\"}",
  )
  relay_websocket.ingest_control_frame(Error("invalid_payload"))
  |> should.equal(
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"relay_protocol\"}",
  )
  relay_websocket.ingest_control_frame(Error("disk_full"))
  |> should.equal(
    "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"hub_storage_error\"}",
  )
}
