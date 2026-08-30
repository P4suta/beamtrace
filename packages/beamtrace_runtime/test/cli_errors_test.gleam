// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/cli_errors
import beamtrace_runtime/storage
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn every_catalogue_entry_is_well_formed_test() {
  let entries = cli_errors.all()
  should.be_true(list.length(entries) > 20)
  list.each(entries, fn(error) {
    should.be_true(string.length(error.code) > 0)
    should.be_true(
      string.to_graphemes(error.code)
      |> list.all(fn(char) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", char)
      }),
    )
    should.be_true(error.message != "")
    should.be_true(string.ends_with(error.hint, "."))
    should.be_true(cli_errors.exit_code(error) != 0)
  })
  let codes = cli_errors.codes()
  should.equal(list.length(codes), list.length(list.unique(codes)))
}

pub fn exit_codes_round_trip_test() {
  list.each(cli_errors.all_exit_codes(), fn(exit) {
    cli_errors.exit_from_int(cli_errors.exit_to_int(exit))
    |> should.equal(Ok(exit))
  })
  cli_errors.exit_from_int(5) |> should.equal(Error(Nil))
  cli_errors.exit_to_int(cli_errors.Interrupted) |> should.equal(130)
  cli_errors.exit_to_int(cli_errors.Terminated) |> should.equal(143)
}

pub fn human_label_is_derived_from_the_json_code_test() {
  cli_errors.human_label(cli_errors.archive_not_found("x"))
  |> should.equal("E_ARCHIVE_NOT_FOUND")
  cli_errors.render_human(cli_errors.archive_not_found("nope.beamtrace"))
  |> should.equal([
    "beamtrace[E_ARCHIVE_NOT_FOUND]: No file exists at 'nope.beamtrace'.",
    "Next: Check the archive path; generated names look like beamtrace-YYYYMMDDTHHMMSSZ.beamtrace.",
  ])
}

pub fn detail_is_rendered_as_an_indented_tail_test() {
  let error =
    cli_errors.child_crashed(1)
    |> cli_errors.with_detail("line one\nline two\n")
  cli_errors.render_human(error)
  |> should.equal([
    "beamtrace[E_CHILD_CRASHED]: The application VM exited during boot with status 1.",
    "Child output (tail):",
    "  line one",
    "  line two",
    "Next: Read the child output tail; fix the boot error and record again.",
  ])
  cli_errors.with_detail(cli_errors.child_crashed(1), "  ").detail
  |> should.equal(None)
}

pub fn storage_errors_map_to_specific_codes_test() {
  let missing =
    cli_errors.from_storage(storage.IoError("enoent"), "nope.beamtrace")
  missing.code |> should.equal("archive_not_found")
  missing.message |> string.contains("nope.beamtrace") |> should.be_true()
  cli_errors.from_storage(storage.InvalidContainer, "x").code
  |> should.equal("invalid_container")
  cli_errors.from_storage(storage.IoError("destination_exists"), "out").code
  |> should.equal("output_exists")
  cli_errors.from_storage(storage.IoError("eacces"), "x").detail
  |> should.equal(Some("eacces"))
}

pub fn capture_reasons_never_leak_raw_atoms_test() {
  let armed = cli_errors.from_capture_reason("arm_timeout")
  armed.code |> should.equal("capture_arm_timeout")
  armed.message |> string.contains("arm_timeout") |> should.be_false()
  cli_errors.from_capture_reason("node_start_timeout").code
  |> should.equal("target_unavailable")
  cli_errors.from_capture_reason("system_tracer_occupied").exit
  |> should.equal(cli_errors.SafetyRefusal)
  cli_errors.from_capture_reason("executable_not_found: erl").code
  |> should.equal("command_not_found")
  cli_errors.from_capture_reason("{badrpc,nodedown}").code
  |> should.equal("target_unreachable")
  let weird = cli_errors.from_capture_reason("{weird,tuple}")
  weird.code |> should.equal("capture_failed")
  weird.message |> string.contains("weird") |> should.be_false()
  weird.detail |> should.equal(Some("{weird,tuple}"))
}

pub fn legacy_messages_keep_their_exit_class_test() {
  cli_errors.legacy("x", 2).code |> should.equal("command_failed")
  cli_errors.legacy("x", 3).code |> should.equal("capture_integrity")
  cli_errors.legacy("x", 4).code |> should.equal("safety_refusal")
  cli_errors.legacy("x", 1).exit |> should.equal(cli_errors.OutcomeDifference)
}

pub fn child_output_is_classified_test() {
  cli_errors.classify_child_output(
    "... Crash dump is being written to: erl_crash.dump ...",
  )
  |> should.equal(Some("child_crashed"))
  cli_errors.classify_child_output("child-ran") |> should.equal(None)
}
