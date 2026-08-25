// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/record_process
import gleam/erlang/process
import gleam/string
import gleeunit/should

@external(erlang, "beamtrace_record_process_test_ffi", "packaged_environment_isolated")
fn packaged_environment_isolated() -> Result(String, String)

@external(erlang, "beamtrace_record_process_test_ffi", "gleam_javascript_target_rejected")
fn gleam_javascript_target_rejected() -> Result(Nil, String)

@external(erlang, "beamtrace_record_process_test_ffi", "temp_gate_contract")
fn temp_gate_contract() -> Result(Nil, String)

@external(erlang, "beamtrace_record_process_test_ffi", "timeout_cleans_gate_and_reports_tail")
fn timeout_cleans_gate_and_reports_tail() -> Result(Nil, String)

@external(erlang, "beamtrace_record_process_test_ffi", "record_signal_cleanup")
fn record_signal_cleanup() -> Result(Nil, String)

@external(erlang, "beamtrace_record_process_test_ffi", "wrapper_trigger_path_preloaded")
fn wrapper_trigger_path_preloaded() -> Result(String, String)

@external(erlang, "beamtrace_record_process_test_ffi", "stopped_child_process_exits")
fn stopped_child_process_exits() -> Result(Nil, String)

@external(erlang, "beamtrace_record_process_test_ffi", "rebar3_wrapper_runs")
fn rebar3_wrapper_runs() -> Result(String, String)

@external(erlang, "beamtrace_record_process_test_ffi", "mix_wrapper_runs")
fn mix_wrapper_runs() -> Result(String, String)

pub fn child_beam_is_held_until_the_one_time_gate_is_released_test() {
  let assert Ok(handle) =
    record_process.start(
      [
        "erl",
        "-noshell",
        "-eval",
        "io:format(\"child-ran\").",
      ],
      "beamtrace_gate_test@localhost",
      "beamtrace_gate_cookie",
      "erlang",
    )
  process.sleep(100)
  record_process.is_running(handle) |> should.be_true()
  record_process.release(handle) |> should.equal(Ok(Nil))
  process.sleep(100)
  record_process.is_running(handle) |> should.be_true()
  record_process.release_finish(handle) |> should.equal(Ok(Nil))
  let assert Ok(#(status, output)) = record_process.await(handle, 30_000)
  status |> should.equal(0)
  output |> string.contains("child-ran") |> should.be_true()
}

pub fn record_uses_private_os_temp_directory_and_cleans_every_marker_test() {
  temp_gate_contract() |> should.equal(Ok(Nil))
}

pub fn record_timeout_reports_the_bounded_tail_and_cleans_the_child_test() {
  timeout_cleans_gate_and_reports_tail() |> should.equal(Ok(Nil))
}

pub fn record_sigterm_cleans_the_child_and_private_temp_directory_test() {
  record_signal_cleanup() |> should.equal(Ok(Nil))
}

pub fn wrapper_trigger_module_is_visible_before_the_start_gate_test() {
  wrapper_trigger_path_preloaded()
  |> should.equal(Ok("BeamTrace demo checkout total: 2500\n"))
}

pub fn rebar3_single_vm_wrapper_compiles_then_runs_behind_the_gate_test() {
  rebar3_wrapper_runs()
  |> should.equal(Ok("rebar-wrapper-ran"))
}

pub fn mix_single_vm_wrapper_compiles_then_runs_behind_the_gate_test() {
  let assert Ok(output) = mix_wrapper_runs()
  should.be_true(output == "mix-wrapper-ran" || output == "skipped")
}

pub fn gleam_wrapper_rejects_the_javascript_target_before_launch_test() {
  gleam_javascript_target_rejected() |> should.equal(Ok(Nil))
}

pub fn stopping_a_gated_command_terminates_its_os_process_test() {
  stopped_child_process_exits() |> should.equal(Ok(Nil))
}

pub fn generated_record_node_is_unique_and_uses_a_short_hostname_test() {
  let assert #(Ok(first), Ok(second_node)) = #(
    record_process.auto_node(),
    record_process.auto_node(),
  )
  should.be_false(first == second_node)
  first |> string.starts_with("beamtrace_") |> should.be_true()
  first |> string.contains("@") |> should.be_true()
}

pub fn gated_child_rejects_flag_injection_before_start_test() {
  record_process.start(
    ["erl", "-noshell"],
    "bad node@localhost",
    "cookie",
    "erlang",
  )
  |> should.equal(Error("record node contains unsafe flag characters"))

  record_process.start(
    ["erl", "-noshell"],
    "safe@localhost",
    "cookie -eval bad",
    "erlang",
  )
  |> should.equal(Error("record cookie contains unsafe flag characters"))
}

pub fn generated_record_cookie_is_bounded_and_flag_safe_test() {
  let assert Ok(cookie) = record_process.ephemeral_cookie()
  string.length(cookie) |> should.equal(48)
  cookie |> string.contains(" ") |> should.be_false()
}

pub fn packaged_runtime_variables_never_leak_into_record_child_test() {
  packaged_environment_isolated()
  |> should.equal(Ok("true"))
}
