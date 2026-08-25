// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/team_control
import gleam/option.{None, Some}
import gleeunit/should

pub fn team_trace_pages_decode_locked_policy_fields_and_opaque_cursor_test() {
  let source =
    "{\"traces\":[{\"id\":\"trace-raw\",\"status\":\"incomplete\","
    <> "\"node\":\"app@host\",\"mfa\":{\"module\":\"shop\",\"function\":\"checkout\",\"arity\":1},"
    <> "\"privacy\":\"raw\",\"completeness\":\"incomplete\",\"event_count\":12,"
    <> "\"received_at_ms\":1000,\"legal_hold\":true,\"locked\":true}],"
    <> "\"next_cursor\":\"NTA\"}"
  let assert Ok(page) = team_control.decode_traces(source)
  page.next_cursor |> should.equal(Some("NTA"))
  let assert [trace] = page.traces
  trace.id |> should.equal("trace-raw")
  trace.privacy |> should.equal("raw")
  trace.locked |> should.be_true()
  trace.legal_hold |> should.be_true()
}

pub fn team_event_pages_keep_events_as_metadata_objects_test() {
  let source =
    "{\"trace_id\":\"trace-metadata\",\"events\":["
    <> "{\"schema_version\":1,\"id\":\"event-team\",\"root_id\":\"root\",\"node\":\"fixture@host\","
    <> "\"process\":{\"physical\":{\"node\":\"fixture@host\",\"pid\":\"<0.1.0>\"},"
    <> "\"logical\":null,\"identity_evidence\":[]},\"local_timestamp_ns\":123,"
    <> "\"event\":{\"kind\":\"stop\",\"reason\":\"done\"},\"evidence\":{\"kind\":\"exact\"}}],"
    <> "\"next_cursor\":null}"
  let assert Ok(page) = team_control.decode_events(source)
  page.trace_id |> should.equal("trace-metadata")
  page.next_cursor |> should.equal(None)
  let assert [event] = page.events
  event.id |> should.equal("event-team")
  event.actor |> should.equal("<0.1.0>")
}
