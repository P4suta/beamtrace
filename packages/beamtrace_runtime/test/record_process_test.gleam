// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/record_process
import gleam/erlang/process
import gleam/string
import gleeunit/should

@external(erlang, "beamtrace_record_process_test_ffi", "packaged_environment_isolated")
fn packaged_environment_isolated() -> Result(String, String)

pub fn child_beam_is_held_until_the_one_time_gate_is_released_test() {
  let assert Ok(handle) =
    record_process.start(
      [
        "erl",
        "-noshell",
        "-eval",
        "io:format(\"child-ran\").",
        "-s",
        "init",
        "stop",
      ],
      "beamtrace_gate_test@localhost",
      "beamtrace_gate_cookie",
    )
  process.sleep(100)
  record_process.is_running(handle) |> should.be_true()
  record_process.release(handle) |> should.equal(Ok(Nil))
  process.sleep(100)
  record_process.is_running(handle) |> should.be_true()
  record_process.release_finish(handle) |> should.equal(Ok(Nil))
  let assert Ok(#(status, output)) = record_process.await(handle, 5000)
  status |> should.equal(0)
  output |> string.contains("child-ran") |> should.be_true()
}

pub fn gated_child_rejects_flag_injection_before_start_test() {
  record_process.start(["erl", "-noshell"], "bad node@localhost", "cookie")
  |> should.equal(Error("record node contains unsafe flag characters"))

  record_process.start(
    ["erl", "-noshell"],
    "safe@localhost",
    "cookie -eval bad",
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
  |> should.equal(Ok("false|false|false"))
}
