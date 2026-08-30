//// Human time labels computed from decimal strings so nanosecond Unix
//// instants never pass through a JavaScript double.

// SPDX-License-Identifier: Apache-2.0 OR MIT

import beamtrace_web/workspace
import gleam/int
import gleam/list
import gleam/string

/// `15893571` → `15.894 ms`; keeps three fraction digits per unit.
pub fn duration_label(ns: Int) -> String {
  let magnitude = int.absolute_value(ns)
  let sign = case ns < 0 {
    True -> "-"
    False -> ""
  }
  sign
  <> case magnitude {
    _ if magnitude < 1000 -> int.to_string(magnitude) <> " ns"
    _ if magnitude < 1_000_000 -> scaled(magnitude, 1000) <> " µs"
    _ if magnitude < 1_000_000_000 -> scaled(magnitude, 1_000_000) <> " ms"
    _ -> scaled(magnitude, 1_000_000_000) <> " s"
  }
}

/// `+15.894 ms` for node-local offsets.
pub fn offset_label(ns: Int) -> String {
  case ns < 0 {
    True -> duration_label(ns)
    False -> "+" <> duration_label(ns)
  }
}

/// Calibrated instant as `YYYY-MM-DD HH:MM:SS.ffffff UTC`, its half-width
/// interval when estimated, and the evidence word; unavailable time keeps
/// its reason.
pub fn instant_label(estimate: workspace.TimeEstimate) -> String {
  case estimate {
    workspace.ExactTime(value) ->
      case civil(value) {
        Ok(text) -> text <> " · exact"
        Error(Nil) -> raw_label(estimate)
      }
    workspace.EstimatedTime(value, lower, upper) ->
      case civil(value), half_width(lower, upper) {
        Ok(text), Ok(width) ->
          text <> " ±" <> duration_label(width) <> " · estimated"
        _, _ -> raw_label(estimate)
      }
    workspace.TimeUnavailable(reason) -> "time unavailable · " <> reason
  }
}

/// Latency deltas and percentiles: `+90 ns ±10 ns · estimated`.
pub fn delta_label(estimate: workspace.TimeEstimate) -> String {
  case estimate {
    workspace.ExactTime(value) ->
      case int.parse(value) {
        Ok(ns) -> offset_label(ns) <> " · exact"
        Error(Nil) -> raw_label(estimate)
      }
    workspace.EstimatedTime(value, lower, upper) ->
      case int.parse(value), half_width(lower, upper) {
        Ok(ns), Ok(width) ->
          offset_label(ns) <> " ±" <> duration_label(width) <> " · estimated"
        _, _ -> raw_label(estimate)
      }
    workspace.TimeUnavailable(reason) -> "time unavailable · " <> reason
  }
}

/// The unformatted decimal values, kept for inspectors and tooltips.
pub fn raw_label(estimate: workspace.TimeEstimate) -> String {
  case estimate {
    workspace.ExactTime(value) -> value <> " ns exact"
    workspace.EstimatedTime(value, lower, upper) ->
      value <> " ns estimated [" <> lower <> ", " <> upper <> "]"
    workspace.TimeUnavailable(reason) -> "time unavailable · " <> reason
  }
}

fn scaled(magnitude: Int, unit: Int) -> String {
  let thousandths = { magnitude * 1000 + unit / 2 } / unit
  int.to_string(thousandths / 1000) <> "." <> pad(thousandths % 1000, 3)
}

fn pad(value: Int, width: Int) -> String {
  string.pad_start(int.to_string(value), width, "0")
}

/// Split a decimal nanosecond string into whole seconds and nanoseconds
/// without parsing the whole value as one integer.
fn split_ns(value: String) -> Result(#(Int, Int), Nil) {
  let digits = string.to_graphemes(value)
  case
    digits != []
    && list.all(digits, fn(digit) { string.contains("0123456789", digit) })
  {
    False -> Error(Nil)
    True -> {
      let length = list.length(digits)
      let seconds_digits = int.max(length - 9, 0)
      let seconds =
        digits |> list.take(seconds_digits) |> string.concat |> parse_or_zero
      let nanos =
        digits |> list.drop(seconds_digits) |> string.concat |> parse_or_zero
      Ok(#(seconds, nanos))
    }
  }
}

fn parse_or_zero(text: String) -> Int {
  case int.parse(text) {
    Ok(value) -> value
    Error(Nil) -> 0
  }
}

fn civil(value: String) -> Result(String, Nil) {
  case split_ns(value) {
    Error(Nil) -> Error(Nil)
    Ok(#(seconds, nanos)) -> {
      let days = seconds / 86_400
      let remainder = seconds % 86_400
      let #(year, month, day) = civil_from_days(days)
      Ok(
        pad(year, 4)
        <> "-"
        <> pad(month, 2)
        <> "-"
        <> pad(day, 2)
        <> " "
        <> pad(remainder / 3600, 2)
        <> ":"
        <> pad(remainder % 3600 / 60, 2)
        <> ":"
        <> pad(remainder % 60, 2)
        <> "."
        <> pad(nanos / 1000, 6)
        <> " UTC",
      )
    }
  }
}

/// Howard Hinnant's civil-from-days for non-negative epoch days.
fn civil_from_days(days: Int) -> #(Int, Int, Int) {
  let z = days + 719_468
  let era = z / 146_097
  let doe = z - era * 146_097
  let yoe = { doe - doe / 1460 + doe / 36_524 - doe / 146_096 } / 365
  let y = yoe + era * 400
  let doy = doe - { 365 * yoe + yoe / 4 - yoe / 100 }
  let mp = { 5 * doy + 2 } / 153
  let d = doy - { 153 * mp + 2 } / 5 + 1
  let m = case mp < 10 {
    True -> mp + 3
    False -> mp - 9
  }
  let year = case m <= 2 {
    True -> y + 1
    False -> y
  }
  #(year, m, d)
}

/// Half of the interval width from two decimal nanosecond strings, computed
/// on the seconds and nanosecond parts separately.
fn half_width(lower: String, upper: String) -> Result(Int, Nil) {
  case split_ns(lower), split_ns(upper) {
    Ok(#(lower_s, lower_ns)), Ok(#(upper_s, upper_ns)) -> {
      let seconds = upper_s - lower_s
      let width = seconds * 1_000_000_000 + upper_ns - lower_ns
      case seconds > 9_000_000 || width < 0 {
        True -> Error(Nil)
        False -> Ok(width / 2)
      }
    }
    _, _ -> Error(Nil)
  }
}
