// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/capture_control
import beamtrace_web/workspace
import gleeunit/should

pub fn target_mfa_candidates_decode_to_bounded_trigger_values_test() {
  capture_control.decode_mfas(
    "{\"candidates\":[{\"node\":\"app@host\",\"module\":\"shop\","
    <> "\"function\":\"checkout\",\"arity\":1,\"mfa\":\"shop:checkout/1\"}]}",
  )
  |> should.equal(Ok(["shop:checkout/1"]))
}

pub fn malformed_mfa_candidate_payload_fails_closed_test() {
  capture_control.decode_mfas("{\"candidates\":[{\"mfa\":42}]}")
  |> should.equal(Error("invalid MFA search response"))
}

pub fn capture_status_names_integrity_issue_and_node_test() {
  capture_control.decode_status(
    "{\"status\":\"sealed\",\"event_count\":7,\"delivery_verified\":false,"
    <> "\"outcome\":{\"end\":{\"kind\":\"quiet_period\",\"quiet_ms\":250},"
    <> "\"issues\":[{\"kind\":\"dropped_events\",\"node\":\"app@host\"}],"
    <> "\"receipts\":[]}}",
  )
  |> should.equal(
    Ok(workspace.Ready(
      7,
      "sealed after 250ms quiet period · integrity issues present (1): dropped events on app@host",
    )),
  )
}

pub fn unverified_delivery_without_issues_is_not_called_an_integrity_issue_test() {
  capture_control.decode_status(
    "{\"status\":\"sealed\",\"event_count\":2,\"delivery_verified\":false,"
    <> "\"outcome\":{\"end\":{\"kind\":\"user_stopped\"},\"issues\":[],\"receipts\":[]}}",
  )
  |> should.equal(
    Ok(workspace.Ready(2, "sealed after user stop · delivery unverified")),
  )
}
