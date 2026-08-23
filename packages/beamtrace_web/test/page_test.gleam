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
  |> should.equal(workspace.Inferred("restart proximity", 0.9))
}

pub fn malformed_page_is_rejected_without_partial_rows_test() {
  page.decode("{\"start\":0,\"limit\":80,\"events\":[]}")
  |> should.be_error()
}
