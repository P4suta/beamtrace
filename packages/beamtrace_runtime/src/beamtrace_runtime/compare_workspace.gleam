// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/dag
import beamtrace/diff
import beamtrace/stats
import beamtrace/types
import beamtrace_runtime/storage
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type RunReport {
  RunReport(
    path: String,
    items: List(diff.DiffItem),
    added: Int,
    removed: Int,
    changed: Int,
    ambiguity_count: Int,
    first_divergence: Option(diff.Divergence),
  )
}

pub type Report {
  Report(
    baseline: String,
    run_count: Int,
    reports: List(RunReport),
    statistics: List(stats.BranchStats),
  )
}

pub type CompareError {
  InvalidPaths
  LoadFailed(path: String, reason: storage.StorageError)
  InvalidTrace(path: String, reason: dag.DagError)
}

type LoadedRun {
  LoadedRun(path: String, events: List(types.TraceEvent))
}

pub fn compare(paths: List(String)) -> Result(Report, CompareError) {
  case valid_paths(paths) {
    False -> Error(InvalidPaths)
    True -> {
      use runs <- result_try(load_runs(paths, []))
      compare_loaded(runs)
    }
  }
}

/// Compare already authorized, decoded event sets. This is used by Team after
/// its storage and raw-trace permission boundaries have loaded each run.
pub fn compare_events(
  runs: List(#(String, List(types.TraceEvent))),
) -> Result(Report, CompareError) {
  case valid_named_runs(runs) {
    False -> Error(InvalidPaths)
    True ->
      runs
      |> list.map(fn(run) { LoadedRun(run.0, run.1) })
      |> compare_loaded
  }
}

fn compare_loaded(runs: List(LoadedRun)) -> Result(Report, CompareError) {
  case runs {
    [] | [_] -> Error(InvalidPaths)
    [baseline, ..candidates] -> {
      use baseline_prepared <- result_try(case diff.prepare(baseline.events) {
        Ok(prepared) -> Ok(prepared)
        Error(error) -> Error(InvalidTrace(baseline.path, error))
      })
      use reports <- result_try(
        compare_candidates(candidates, baseline_prepared, []),
      )
      Ok(Report(
        baseline: baseline.path,
        run_count: list.length(runs),
        reports: reports,
        statistics: runs
          |> list.map(fn(run) { run.events })
          |> stats.from_traces,
      ))
    }
  }
}

fn compare_candidates(
  candidates: List(LoadedRun),
  baseline: diff.PreparedTrace,
  accumulator: List(RunReport),
) -> Result(List(RunReport), CompareError) {
  case candidates {
    [] -> Ok(list.reverse(accumulator))
    [candidate, ..rest] ->
      case diff.prepare(candidate.events) {
        Error(error) -> Error(InvalidTrace(candidate.path, error))
        Ok(prepared) -> {
          let report = diff.compare_prepared(baseline, prepared)
          compare_candidates(rest, baseline, [
            RunReport(
              path: candidate.path,
              items: report.items,
              added: report.added,
              removed: report.removed,
              changed: report.changed,
              ambiguity_count: report.ambiguity_count,
              first_divergence: report.first_divergence,
            ),
            ..accumulator
          ])
        }
      }
  }
}

fn valid_paths(paths: List(String)) -> Bool {
  let count = list.length(paths)
  count >= 2
  && count <= 20
  && list.all(paths, fn(path) {
    let normalized = string.trim(path)
    normalized == path
    && normalized != ""
    && string.byte_size(normalized) <= 4096
    && string.ends_with(string.lowercase(normalized), ".beamtrace")
  })
  && no_duplicates(paths, [])
}

fn valid_named_runs(runs: List(#(String, List(types.TraceEvent)))) -> Bool {
  let count = list.length(runs)
  let names = list.map(runs, fn(run) { run.0 })
  count >= 2
  && count <= 20
  && list.all(names, fn(name) { name != "" && string.byte_size(name) <= 4096 })
  && no_duplicates(names, [])
}

fn no_duplicates(paths: List(String), seen: List(String)) -> Bool {
  case paths {
    [] -> True
    [path, ..rest] ->
      case list.contains(seen, path) {
        True -> False
        False -> no_duplicates(rest, [path, ..seen])
      }
  }
}

fn load_runs(
  paths: List(String),
  accumulator: List(LoadedRun),
) -> Result(List(LoadedRun), CompareError) {
  case paths {
    [] -> Ok(list.reverse(accumulator))
    [path, ..rest] ->
      case storage.load(path) {
        Error(reason) -> Error(LoadFailed(path, reason))
        Ok(archive) ->
          load_runs(rest, [LoadedRun(path, archive.events), ..accumulator])
      }
  }
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}
