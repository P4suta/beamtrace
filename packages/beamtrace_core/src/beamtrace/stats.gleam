// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/diff
import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type BranchSample {
  BranchSample(signature: String, duration_ns: Int)
}

pub type BranchStats {
  BranchStats(
    signature: String,
    p50_ns: Int,
    p95_ns: Int,
    occurrences: Int,
    total_runs: Int,
    occurrence_rate: Float,
  )
}

/// Summarise complete trace runs without depending on physical PIDs or each
/// node's wall-clock origin. Every event latency is measured from the earliest
/// observed event in the same causal root.
pub fn from_traces(runs: List(List(types.TraceEvent))) -> List(BranchStats) {
  runs
  |> list.map(fn(run) {
    list.map(run, fn(event) {
      BranchSample(
        signature: diff.signature(event),
        duration_ns: event.local_timestamp_ns - root_origin(run, event.root_id),
      )
    })
  })
  |> summarize
}

pub fn summarize(runs: List(List(BranchSample))) -> List(BranchStats) {
  let signatures =
    runs
    |> list.flat_map(fn(run) { list.map(run, fn(sample) { sample.signature }) })
    |> unique([])
    |> list.sort(string.compare)
  let total_runs = list.length(runs)

  list.map(signatures, fn(signature) {
    let durations =
      runs
      |> list.flat_map(fn(run) {
        run
        |> list.filter(fn(sample) { sample.signature == signature })
        |> list.map(fn(sample) { sample.duration_ns })
      })
      |> list.sort(int.compare)
    let occurrences =
      runs
      |> list.filter(fn(run) {
        list.any(run, fn(sample) { sample.signature == signature })
      })
      |> list.length
    BranchStats(
      signature: signature,
      p50_ns: percentile(durations, 50),
      p95_ns: percentile(durations, 95),
      occurrences: occurrences,
      total_runs: total_runs,
      occurrence_rate: case total_runs {
        0 -> 0.0
        _ -> int.to_float(occurrences) /. int.to_float(total_runs)
      },
    )
  })
}

fn percentile(sorted: List(Int), percent: Int) -> Int {
  let count = list.length(sorted)
  case count {
    0 -> 0
    _ -> {
      let rank = { count * percent + 99 } / 100
      case sorted |> list.drop(rank - 1) |> list.first {
        Ok(value) -> value
        Error(_) -> 0
      }
    }
  }
}

fn root_origin(events: List(types.TraceEvent), root_id: String) -> Int {
  root_origin_loop(events, root_id, None)
}

fn root_origin_loop(
  events: List(types.TraceEvent),
  root_id: String,
  found: Option(Int),
) -> Int {
  case events {
    [] ->
      case found {
        Some(value) -> value
        None -> 0
      }
    [event, ..rest] -> {
      let found = case event.root_id == root_id, found {
        False, _ -> found
        True, None -> Some(event.local_timestamp_ns)
        True, Some(value) ->
          case event.local_timestamp_ns < value {
            True -> Some(event.local_timestamp_ns)
            False -> found
          }
      }
      root_origin_loop(rest, root_id, found)
    }
  }
}

fn unique(items: List(String), accumulator: List(String)) -> List(String) {
  case items {
    [] -> list.reverse(accumulator)
    [item, ..rest] ->
      case list.contains(accumulator, item) {
        True -> unique(rest, accumulator)
        False -> unique(rest, [item, ..accumulator])
      }
  }
}
