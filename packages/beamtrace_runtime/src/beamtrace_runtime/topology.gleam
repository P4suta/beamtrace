// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string

pub type ProcessSnapshot {
  ProcessSnapshot(
    id: String,
    supervisor_parent: Option(String),
    spawn_parent: Option(String),
    links: List(String),
  )
}

pub type Edge {
  Edge(from: String, to: String, evidence: types.Evidence)
}

pub type Graphs {
  Graphs(supervision: List(Edge), spawn: List(Edge), links: List(Edge))
}

pub fn build(snapshots: List(ProcessSnapshot)) -> Graphs {
  Graphs(
    supervision: list.filter_map(snapshots, fn(snapshot) {
      case snapshot.supervisor_parent {
        Some(parent) -> Ok(Edge(parent, snapshot.id, types.Exact))
        None -> Error(Nil)
      }
    }),
    spawn: list.filter_map(snapshots, fn(snapshot) {
      case snapshot.spawn_parent {
        Some(parent) -> Ok(Edge(parent, snapshot.id, types.Exact))
        None -> Error(Nil)
      }
    }),
    links: link_edges(snapshots, []),
  )
}

fn link_edges(
  snapshots: List(ProcessSnapshot),
  accumulator: List(Edge),
) -> List(Edge) {
  case snapshots {
    [] -> list.reverse(accumulator)
    [snapshot, ..rest] -> {
      let next =
        list.fold(snapshot.links, accumulator, fn(edges, peer) {
          let #(from, to) = normalized_pair(snapshot.id, peer)
          let edge = Edge(from, to, types.Exact)
          case list.contains(edges, edge) {
            True -> edges
            False -> [edge, ..edges]
          }
        })
      link_edges(rest, next)
    }
  }
}

fn normalized_pair(left: String, right: String) -> #(String, String) {
  case string.compare(left, right) {
    order.Gt -> #(right, left)
    order.Eq | order.Lt -> #(left, right)
  }
}
