// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/page
import beamtrace_web/workspace
import gleam/dynamic/decode
import gleam/json
import gleam/string
import lustre/effect.{type Effect}

pub type GraphPayload {
  GraphPayload(
    edges: List(workspace.GraphEdge),
    boundaries: List(workspace.GraphBoundary),
  )
}

pub fn load() -> Effect(workspace.Msg) {
  effect.from(fn(dispatch) {
    fetch_graph(
      fn(body) {
        case decode_graph(body) {
          Ok(graph) ->
            dispatch(workspace.GraphLoaded(graph.edges, graph.boundaries))
          Error(reason) -> dispatch(workspace.GraphLoadFailed(reason))
        }
      },
      fn(reason) { dispatch(workspace.GraphLoadFailed(reason)) },
    )
  })
}

pub fn decode_graph(source: String) -> Result(GraphPayload, String) {
  case json.parse(source, graph_decoder()) {
    Ok(graph) -> Ok(graph)
    Error(error) -> Error(string.inspect(error))
  }
}

fn graph_decoder() -> decode.Decoder(GraphPayload) {
  use _version <- decode.field("schema_version", decode.int)
  use edges <- decode.field("edges", decode.list(edge_decoder()))
  use boundaries <- decode.field("boundaries", decode.list(boundary_decoder()))
  decode.success(GraphPayload(edges, boundaries))
}

fn edge_decoder() -> decode.Decoder(workspace.GraphEdge) {
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  use kind <- decode.field("kind", edge_kind_decoder())
  use evidence <- decode.field("evidence", page.evidence_decoder())
  decode.success(workspace.GraphEdge(from, to, kind, evidence))
}

fn boundary_decoder() -> decode.Decoder(workspace.GraphBoundary) {
  use event_id <- decode.field("event_id", decode.string)
  use kind <- decode.field("kind", edge_kind_decoder())
  use reason <- decode.field("reason", decode.string)
  decode.success(workspace.GraphBoundary(event_id, kind, reason))
}

fn edge_kind_decoder() -> decode.Decoder(String) {
  use kind <- decode.field("kind", decode.string)
  decode.success(kind)
}

@external(javascript, "./graph_control_ffi.mjs", "fetchGraph")
fn fetch_graph(
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil
