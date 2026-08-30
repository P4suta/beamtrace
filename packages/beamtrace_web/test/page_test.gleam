// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/page
import beamtrace_web/workspace
import gleeunit/should

pub fn api_page_decodes_only_renderable_metadata_test() {
  let source =
    "{\"start\":100,\"limit\":2,\"total\":1000000,\"events\":["
    <> "{\"schema_version\":1,\"id\":\"event-101\",\"root_id\":\"root\",\"node\":\"fixture@host\","
    <> "\"process\":{\"physical\":{\"node\":\"fixture@host\",\"pid\":\"<0.1.0>\"},"
    <> "\"logical\":{\"id\":\"slot-cart\",\"label\":\"cart_server\"},\"identity_evidence\":[]},"
    <> "\"local_timestamp_ns\":123,\"event\":{\"kind\":\"exit\",\"reason\":{\"kind\":\"hidden\"}},"
    <> "\"evidence\":{\"kind\":\"inferred\",\"reason\":\"restart proximity\",\"confidence\":0.9}}]}"

  let assert Ok(decoded) = page.decode(source)
  decoded.start |> should.equal(100)
  decoded.total |> should.equal(1_000_000)
  let assert [row] = decoded.events
  row.actor |> should.equal("cart_server")
  row.kind |> should.equal("exit")
  row.anomalous |> should.be_true()
  row.evidence
  |> should.equal(workspace.Inferred("legacy_v1_inference", "restart proximity"))
}

pub fn malformed_page_is_rejected_without_partial_rows_test() {
  page.decode("{\"start\":0,\"limit\":80,\"events\":[]}")
  |> should.be_error()
}

pub fn otp_system_processes_are_folded_as_internal_test() {
  let row = fn(actor: String) {
    let source =
      "{\"start\":0,\"limit\":1,\"total\":1,\"events\":["
      <> "{\"schema_version\":1,\"id\":\"event-1\",\"root_id\":\"root\",\"node\":\"fixture@host\","
      <> "\"process\":{\"physical\":{\"node\":\"fixture@host\",\"pid\":\"<0.1.0>\"},"
      <> "\"logical\":{\"id\":\""
      <> actor
      <> "\",\"label\":\""
      <> actor
      <> "\"},\"identity_evidence\":[]},"
      <> "\"local_timestamp_ns\":1,\"event\":{\"kind\":\"exit\",\"reason\":{\"kind\":\"hidden\"}},"
      <> "\"evidence\":{\"kind\":\"exact\"}}]}"
    let assert Ok(decoded) = page.decode(source)
    let assert [row] = decoded.events
    row.internal
  }
  row("user_drv") |> should.be_true()
  row("init") |> should.be_true()
  row("application_controller") |> should.be_true()
  row("logger_proxy") |> should.be_true()
  row("beamtrace_agent") |> should.be_true()
  row("checkout") |> should.be_false()
  row("cart_server") |> should.be_false()
}
