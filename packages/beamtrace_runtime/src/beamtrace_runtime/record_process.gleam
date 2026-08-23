// SPDX-License-Identifier: Apache-2.0 OR MIT

/// A child command paused during Erlang boot until BeamTrace has attached and
/// armed its exact trace. The opaque handle owns both the OS port and its
/// one-time gate file.
pub type Handle

pub fn start(
  command: List(String),
  node: String,
  cookie: String,
) -> Result(Handle, String) {
  start_gated_command(command, node, cookie)
}

pub fn release(handle: Handle) -> Result(Nil, String) {
  release_gated_command(handle)
}

/// Release the post-command gate after capture cleanup is complete. Direct
/// `erl` commands are held here before `init:stop`; wrappers without a safe
/// post-command insertion treat this as a no-op.
pub fn release_finish(handle: Handle) -> Result(Nil, String) {
  release_gated_command_finish(handle)
}

pub fn await(
  handle: Handle,
  timeout_ms: Int,
) -> Result(#(Int, String), String) {
  await_gated_command(handle, timeout_ms)
}

pub fn stop(handle: Handle) -> Nil {
  stop_gated_command(handle)
}

pub fn is_running(handle: Handle) -> Bool {
  gated_command_running(handle)
}

pub fn ephemeral_cookie() -> Result(String, String) {
  read_record_cookie()
}

@external(erlang, "beamtrace_cli_ffi", "start_gated_command")
fn start_gated_command(
  command: List(String),
  node: String,
  cookie: String,
) -> Result(Handle, String)

@external(erlang, "beamtrace_cli_ffi", "release_gated_command")
fn release_gated_command(handle: Handle) -> Result(Nil, String)

@external(erlang, "beamtrace_cli_ffi", "release_gated_command_finish")
fn release_gated_command_finish(handle: Handle) -> Result(Nil, String)

@external(erlang, "beamtrace_cli_ffi", "await_gated_command")
fn await_gated_command(
  handle: Handle,
  timeout_ms: Int,
) -> Result(#(Int, String), String)

@external(erlang, "beamtrace_cli_ffi", "stop_gated_command")
fn stop_gated_command(handle: Handle) -> Nil

@external(erlang, "beamtrace_cli_ffi", "gated_command_running")
fn gated_command_running(handle: Handle) -> Bool

@external(erlang, "beamtrace_cli_ffi", "read_record_cookie")
fn read_record_cookie() -> Result(String, String)
