// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/capture_control
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
