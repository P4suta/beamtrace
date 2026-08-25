// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/live_control
import beamtrace_web/workspace
import gleam/list
import gleeunit/should

pub fn live_response_decodes_samples_findings_topology_and_evidence_test() {
  let source =
    "{\"node\":\"app@host\",\"generation\":2,\"sampled_at_ms\":1603,"
    <> "\"next_offset\":2,\"samples\":[{\"node\":\"app@host\","
    <> "\"pid\":\"<0.42.0>\",\"label\":\"orders worker\","
    <> "\"registered_name\":\"orders\",\"process_label\":\"orders worker\","
    <> "\"initial_call\":\"orders_worker:init/1\",\"mailbox_len\":50,"
    <> "\"memory_bytes\":10000,\"reductions\":1000,\"heap_words\":100,"
    <> "\"total_heap_words\":200,\"link_count\":1,\"status\":\"waiting\","
    <> "\"current_function\":\"gen_server:loop/7\",\"links\":[\"<0.7.0>\"],"
    <> "\"ancestors\":[\"orders_sup\"]}],\"findings\":[{\"pid\":\"<0.42.0>\","
    <> "\"label\":\"orders worker\",\"kind\":\"mailbox_growth\","
    <> "\"summary\":\"mailbox is growing\",\"evidence\":{\"kind\":\"inferred\","
    <> "\"inference\":{\"method\":\"ewma_hysteresis\",\"reason\":\"EWMA\","
    <> "\"inputs\":[]}}}],\"topology\":{"
    <> "\"supervision\":[{\"from\":\"orders_sup\",\"to\":\"<0.42.0>\","
    <> "\"evidence\":{\"kind\":\"inferred\",\"inference\":{"
    <> "\"method\":\"proc_lib_ancestor\",\"reason\":\"proc_lib\","
    <> "\"inputs\":[]}}}],\"spawn\":[],\"links\":[{\"from\":\"<0.7.0>\","
    <> "\"to\":\"<0.42.0>\",\"evidence\":{\"kind\":\"exact\"}}]}}"
  let assert Ok(snapshot) = live_control.decode_snapshot(source)
  snapshot.generation |> should.equal(2)
  snapshot.rows |> list.length |> should.equal(1)
  snapshot.findings
  |> list.first
  |> should.equal(
    Ok(workspace.LiveFinding(
      "<0.42.0>",
      "orders worker",
      "mailbox_growth",
      "mailbox is growing",
      workspace.Inferred("ewma_hysteresis", "EWMA"),
    )),
  )
  snapshot.links
  |> should.equal([
    workspace.TopologyEdge("<0.7.0>", "<0.42.0>", workspace.Exact),
  ])
}

pub fn malformed_or_unknown_evidence_is_rejected_test() {
  live_control.decode_snapshot("{}") |> should.be_error()
}
