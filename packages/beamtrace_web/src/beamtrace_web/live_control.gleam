// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/json
import gleam/string
import lustre/effect.{type Effect}

type TopologyPayload {
  TopologyPayload(
    supervision: List(workspace.TopologyEdge),
    spawn: List(workspace.TopologyEdge),
    links: List(workspace.TopologyEdge),
  )
}

pub fn load() -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    fetch_live(
      fn(body) {
        case decode_snapshot(body) {
          Ok(snapshot) -> dispatch(workspace.LiveLoaded(snapshot))
          Error(reason) -> dispatch(workspace.LiveLoadFailed(reason))
        }
      },
      fn(reason) { dispatch(workspace.LiveLoadFailed(reason)) },
    )
  })
}

pub fn poll_after(delay_ms: Int) -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    schedule(delay_ms, fn() { dispatch(workspace.PollLive) })
  })
}

pub fn decode_snapshot(
  source: String,
) -> Result(workspace.LiveSnapshot, String) {
  case json.parse(source, snapshot_decoder()) {
    Ok(snapshot) -> Ok(snapshot)
    Error(errors) -> Error(string.inspect(errors))
  }
}

fn snapshot_decoder() -> decode.Decoder(workspace.LiveSnapshot) {
  use _node <- decode.field("node", decode.string)
  use generation <- decode.field("generation", decode.int)
  use sampled_at_ms <- decode.field("sampled_at_ms", decode.int)
  use _next_offset <- decode.field("next_offset", decode.int)
  use rows <- decode.field("samples", decode.list(row_decoder()))
  use findings <- decode.field("findings", decode.list(finding_decoder()))
  use topology <- decode.field("topology", topology_decoder())
  decode.success(workspace.LiveSnapshot(
    generation,
    sampled_at_ms,
    rows,
    findings,
    topology.supervision,
    topology.spawn,
    topology.links,
  ))
}

fn row_decoder() -> decode.Decoder(workspace.LiveRow) {
  use node <- decode.field("node", decode.string)
  use pid <- decode.field("pid", decode.string)
  use label <- decode.field("label", decode.string)
  use registered_name <- decode.field("registered_name", decode.string)
  use process_label <- decode.field("process_label", decode.string)
  use initial_call <- decode.field("initial_call", decode.string)
  use mailbox_len <- decode.field("mailbox_len", decode.int)
  use memory_bytes <- decode.field("memory_bytes", decode.int)
  use reductions <- decode.field("reductions", decode.int)
  use heap_words <- decode.field("heap_words", decode.int)
  use total_heap_words <- decode.field("total_heap_words", decode.int)
  use link_count <- decode.field("link_count", decode.int)
  use status <- decode.field("status", decode.string)
  use current_function <- decode.field("current_function", decode.string)
  use links <- decode.field("links", decode.list(decode.string))
  use ancestors <- decode.field("ancestors", decode.list(decode.string))
  decode.success(workspace.LiveRow(
    node,
    pid,
    label,
    registered_name,
    process_label,
    initial_call,
    mailbox_len,
    memory_bytes,
    reductions,
    heap_words,
    total_heap_words,
    link_count,
    status,
    current_function,
    links,
    ancestors,
  ))
}

fn finding_decoder() -> decode.Decoder(workspace.LiveFinding) {
  use pid <- decode.field("pid", decode.string)
  use label <- decode.field("label", decode.string)
  use kind <- decode.field("kind", decode.string)
  use summary <- decode.field("summary", decode.string)
  use evidence <- decode.field("evidence", evidence_decoder())
  decode.success(workspace.LiveFinding(pid, label, kind, summary, evidence))
}

fn topology_decoder() -> decode.Decoder(TopologyPayload) {
  use supervision <- decode.field(
    "supervision",
    decode.list(topology_edge_decoder()),
  )
  use spawn <- decode.field("spawn", decode.list(topology_edge_decoder()))
  use links <- decode.field("links", decode.list(topology_edge_decoder()))
  decode.success(TopologyPayload(supervision, spawn, links))
}

fn topology_edge_decoder() -> decode.Decoder(workspace.TopologyEdge) {
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  use evidence <- decode.field("evidence", evidence_decoder())
  decode.success(workspace.TopologyEdge(from, to, evidence))
}

fn evidence_decoder() -> decode.Decoder(workspace.Evidence) {
  use status <- decode.field("status", decode.string)
  case status {
    "exact" -> decode.success(workspace.Exact)
    "inferred" -> {
      use reason <- decode.field("reason", decode.string)
      use confidence <- decode.field("confidence", decode.float)
      decode.success(workspace.Inferred(reason, confidence))
    }
    _ -> decode.failure(workspace.Exact, expected: "live evidence")
  }
}

@external(javascript, "./live_control_ffi.mjs", "fetchLive")
fn fetch_live(on_success: fn(String) -> Nil, on_error: fn(String) -> Nil) -> Nil

@external(javascript, "./live_control_ffi.mjs", "schedule")
fn schedule(delay_ms: Int, callback: fn() -> Nil) -> Nil
