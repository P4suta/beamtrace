// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/time_format
import beamtrace_web/workspace
import gleeunit/should

pub fn durations_use_three_fraction_digits_per_unit_test() {
  time_format.duration_label(999) |> should.equal("999 ns")
  time_format.duration_label(1500) |> should.equal("1.500 µs")
  time_format.duration_label(15_893_571) |> should.equal("15.894 ms")
  time_format.duration_label(2_000_000_000) |> should.equal("2.000 s")
  time_format.offset_label(15_893_571) |> should.equal("+15.894 ms")
  time_format.offset_label(-2000) |> should.equal("-2.000 µs")
}

pub fn instants_render_civil_utc_time_from_decimal_strings_test() {
  time_format.instant_label(workspace.ExactTime("0"))
  |> should.equal("1970-01-01 00:00:00.000000 UTC · exact")
  time_format.instant_label(workspace.ExactTime("1709164800000000000"))
  |> should.equal("2024-02-29 00:00:00.000000 UTC · exact")
  time_format.instant_label(workspace.EstimatedTime(
    "1774000000000000200",
    "1774000000000000150",
    "1774000000000000250",
  ))
  |> should.equal("2026-03-20 09:46:40.000000 UTC ±50 ns · estimated")
  time_format.instant_label(workspace.EstimatedTime(
    "1788090105011610338",
    "1788090105011580258",
    "1788090105011640420",
  ))
  |> should.equal("2026-08-30 11:41:45.011610 UTC ±30.081 µs · estimated")
  time_format.instant_label(workspace.TimeUnavailable("no_calibration"))
  |> should.equal("time unavailable · no_calibration")
}

pub fn deltas_keep_intervals_and_evidence_test() {
  time_format.delta_label(workspace.EstimatedTime("90", "80", "100"))
  |> should.equal("+90 ns ±10 ns · estimated")
  time_format.delta_label(workspace.ExactTime("10"))
  |> should.equal("+10 ns · exact")
}

pub fn reversed_bounds_fall_back_to_the_raw_label_test() {
  time_format.instant_label(workspace.EstimatedTime(
    "2000500000",
    "2000900000",
    "2000000000",
  ))
  |> should.equal("2000500000 ns estimated [2000900000, 2000000000]")
}

pub fn malformed_values_fall_back_to_the_raw_label_test() {
  time_format.instant_label(workspace.ExactTime("not-a-number"))
  |> should.equal("not-a-number ns exact")
  time_format.raw_label(workspace.EstimatedTime("1", "0", "2"))
  |> should.equal("1 ns estimated [0, 2]")
}
