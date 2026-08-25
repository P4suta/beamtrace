// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/diff
import beamtrace/types
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type BranchSample {
  BranchSample(signature: String, duration: types.TimeEstimate)
}

pub type BranchStats {
  BranchStats(
    signature: String,
    p50: types.TimeSummary,
    p95: types.TimeSummary,
    occurrences: Int,
    total_runs: Int,
  )
}

type Aggregate {
  Aggregate(samples: List(types.TimeEstimate), occurrences: Int)
}

/// Same-node root-relative samples are exact. If the root origin for the
/// event's node is absent, the sample remains unavailable and is counted.
pub fn from_traces(runs: List(List(types.TraceEvent))) -> List(BranchStats) {
  runs
  |> list.map(fn(run) {
    let origins = root_origins(run)
    list.map(run, fn(event) {
      BranchSample(diff.signature(event), event_duration(origins, event))
    })
  })
  |> summarize
}

pub fn summarize(runs: List(List(BranchSample))) -> List(BranchStats) {
  let total_runs = list.length(runs)
  let aggregate =
    list.fold(runs, dict.new(), fn(all, run) {
      let in_run =
        list.fold(run, dict.new(), fn(index, sample) {
          let durations = dict.get(index, sample.signature) |> result.unwrap([])
          dict.insert(index, sample.signature, [sample.duration, ..durations])
        })
      list.fold(dict.to_list(in_run), all, fn(index, entry) {
        let #(signature, durations) = entry
        let current =
          dict.get(index, signature) |> result.unwrap(Aggregate([], 0))
        dict.insert(
          index,
          signature,
          Aggregate(
            list.append(durations, current.samples),
            current.occurrences + 1,
          ),
        )
      })
    })
  aggregate
  |> dict.to_list
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.map(fn(entry) {
    let #(signature, aggregate) = entry
    BranchStats(
      signature,
      percentile_summary(aggregate.samples, 50),
      percentile_summary(aggregate.samples, 95),
      aggregate.occurrences,
      total_runs,
    )
  })
}

fn event_duration(
  origins: Dict(String, Int),
  event: types.TraceEvent,
) -> types.TimeEstimate {
  case dict.get(origins, root_key(event.root_id, event.node)) {
    Ok(origin) -> types.ExactTime(event.local_instant.offset_ns - origin)
    Error(_) -> types.TimeUnavailable("same-node root origin was not observed")
  }
}

fn percentile_summary(
  samples: List(types.TimeEstimate),
  percent: Int,
) -> types.TimeSummary {
  let valid = list.filter_map(samples, estimate_tuple)
  let missing = list.length(samples) - list.length(valid)
  let estimate = case valid {
    [] -> types.TimeUnavailable("no valid time samples")
    _ -> {
      let centers =
        list.map(valid, fn(sample) { sample.0 }) |> list.sort(int.compare)
      let lowers =
        list.map(valid, fn(sample) { sample.1 }) |> list.sort(int.compare)
      let uppers =
        list.map(valid, fn(sample) { sample.2 }) |> list.sort(int.compare)
      let center = percentile(centers, percent)
      let lower = percentile(lowers, percent)
      let upper = percentile(uppers, percent)
      case lower == center && center == upper {
        True -> types.ExactTime(center)
        False -> types.EstimatedTime(center, lower, upper)
      }
    }
  }
  types.TimeSummary(estimate, list.length(valid), missing)
}

fn estimate_tuple(
  estimate: types.TimeEstimate,
) -> Result(#(Int, Int, Int), Nil) {
  case estimate {
    types.ExactTime(value) -> Ok(#(value, value, value))
    types.EstimatedTime(value, lower, upper) -> Ok(#(value, lower, upper))
    types.TimeUnavailable(_) -> Error(Nil)
  }
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

fn root_origins(events: List(types.TraceEvent)) -> Dict(String, Int) {
  list.fold(events, dict.new(), fn(origins, event) {
    let key = root_key(event.root_id, event.node)
    case dict.get(origins, key) {
      Ok(value) ->
        dict.insert(origins, key, int.min(value, event.local_instant.offset_ns))
      Error(_) -> dict.insert(origins, key, event.local_instant.offset_ns)
    }
  })
}

fn root_key(root_id: String, node: String) -> String {
  root_id <> "\u{0}" <> node
}
