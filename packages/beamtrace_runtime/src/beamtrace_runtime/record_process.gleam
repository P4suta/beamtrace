// SPDX-License-Identifier: Apache-2.0 OR MIT

/// A child command paused during Erlang boot until BeamTrace has attached and
/// armed its exact trace. The opaque handle owns both the OS port and its
/// one-time gate file.
pub type Handle

pub fn start(
  command: List(String),
  node: String,
  cookie: String,
  trigger_module: String,
) -> Result(Handle, String) {
  start_gated_command(command, node, cookie, trigger_module, [])
}

/// Start a child whose BeamTrace-owned modules are staged into the private
/// gate directory, so the bundled demo needs no host code path.
pub fn start_staged(
  command: List(String),
  node: String,
  cookie: String,
  trigger_module: String,
  staged_modules: List(String),
) -> Result(Handle, String) {
  start_gated_command(command, node, cookie, trigger_module, staged_modules)
}

pub fn release(handle: Handle) -> Result(Nil, String) {
  release_gated_command(handle)
}

/// Release the post-command gate after capture cleanup is complete. A tiny
/// injected OTP shutdown guard holds both direct `erl` and wrapper-driven VMs
/// here even when a wrapper places `ERL_ZFLAGS` after its argument terminator.
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

/// Return the conventional process exit status requested by SIGINT/SIGTERM,
/// or zero while no record shutdown is in progress.
pub fn shutdown_exit_code() -> Int {
  record_shutdown_exit_code()
}

pub fn ephemeral_cookie() -> Result(String, String) {
  read_record_cookie()
}

/// Generate a unique short-name target matching the host Erlang will use for
/// `-sname`. Callers may still supply an explicit long or short node name.
pub fn auto_node() -> Result(String, String) {
  auto_record_node()
}

pub fn demo_command() -> Result(List(String), String) {
  bundled_demo_command()
}

@external(erlang, "beamtrace_cli_ffi", "start_gated_command")
fn start_gated_command(
  command: List(String),
  node: String,
  cookie: String,
  trigger_module: String,
  staged_modules: List(String),
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

@external(erlang, "beamtrace_cli_ffi", "record_shutdown_exit_code")
fn record_shutdown_exit_code() -> Int

@external(erlang, "beamtrace_cli_ffi", "read_record_cookie")
fn read_record_cookie() -> Result(String, String)

@external(erlang, "beamtrace_cli_ffi", "auto_record_node")
fn auto_record_node() -> Result(String, String)

@external(erlang, "beamtrace_cli_ffi", "demo_command")
fn bundled_demo_command() -> Result(List(String), String)
