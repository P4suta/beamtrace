//// One error catalogue shared by human and JSON output.

// SPDX-License-Identifier: Apache-2.0 OR MIT

import beamtrace_runtime/storage
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type ExitCode {
  Success
  OutcomeDifference
  CommandFailed
  CaptureIntegrity
  SafetyRefusal
  Interrupted
  Terminated
}

pub fn exit_to_int(exit: ExitCode) -> Int {
  case exit {
    Success -> 0
    OutcomeDifference -> 1
    CommandFailed -> 2
    CaptureIntegrity -> 3
    SafetyRefusal -> 4
    Interrupted -> 130
    Terminated -> 143
  }
}

pub fn exit_from_int(code: Int) -> Result(ExitCode, Nil) {
  case code {
    0 -> Ok(Success)
    1 -> Ok(OutcomeDifference)
    2 -> Ok(CommandFailed)
    3 -> Ok(CaptureIntegrity)
    4 -> Ok(SafetyRefusal)
    130 -> Ok(Interrupted)
    143 -> Ok(Terminated)
    _ -> Error(Nil)
  }
}

pub fn all_exit_codes() -> List(ExitCode) {
  [
    Success,
    OutcomeDifference,
    CommandFailed,
    CaptureIntegrity,
    SafetyRefusal,
    Interrupted,
    Terminated,
  ]
}

pub fn exit_description(exit: ExitCode) -> String {
  case exit {
    Success -> "success"
    OutcomeDifference -> "comparison difference or application exit status"
    CommandFailed -> "usage, connection, configuration, or storage failure"
    CaptureIntegrity -> "capture integrity issue"
    SafetyRefusal -> "safety refusal"
    Interrupted -> "record interrupted by SIGINT"
    Terminated -> "record terminated by SIGTERM"
  }
}

pub type CliError {
  CliError(
    code: String,
    exit: ExitCode,
    message: String,
    hint: String,
    detail: Option(String),
  )
}

pub fn exit_code(error: CliError) -> Int {
  exit_to_int(error.exit)
}

/// `E_` followed by the upper-cased JSON code.
pub fn human_label(error: CliError) -> String {
  "E_" <> string.uppercase(error.code)
}

pub fn render_human(error: CliError) -> List(String) {
  let head = "beamtrace[" <> human_label(error) <> "]: " <> error.message
  let detail = case error.detail {
    None -> []
    Some(text) -> [
      "Child output (tail):",
      ..list.map(string.split(string.trim(text), on: "\n"), fn(line) {
        "  " <> line
      })
    ]
  }
  list.append([head, ..detail], ["Next: " <> error.hint])
}

pub fn with_detail(error: CliError, detail: String) -> CliError {
  case string.trim(detail) {
    "" -> error
    text -> CliError(..error, detail: Some(text))
  }
}

/// Bridge for call sites that still pass a free-form message and exit code.
pub fn legacy(message: String, code: Int) -> CliError {
  let exit = case exit_from_int(code) {
    Ok(exit) -> exit
    Error(Nil) -> CommandFailed
  }
  case exit {
    CaptureIntegrity -> capture_integrity(message)
    SafetyRefusal -> safety_refusal(message)
    CommandFailed -> command_failed(message)
    _ -> CliError("operation_outcome", exit, message, retry_hint(), None)
  }
}

fn retry_hint() -> String {
  "Inspect the reported outcome before deciding whether to retry."
}

pub fn invalid_arguments(message: String) -> CliError {
  CliError(
    "invalid_arguments",
    CommandFailed,
    message,
    "Run 'beamtrace help <command>' for accepted options and examples.",
    None,
  )
}

pub fn command_failed(message: String) -> CliError {
  CliError(
    "command_failed",
    CommandFailed,
    message,
    "Run 'beamtrace doctor' and then 'beamtrace help <command>' before retrying.",
    None,
  )
}

pub fn capture_integrity(message: String) -> CliError {
  CliError(
    "capture_integrity",
    CaptureIntegrity,
    message,
    "Inspect delivery issues, repair the named node or transport, and capture again.",
    None,
  )
}

pub fn safety_refusal(message: String) -> CliError {
  CliError(
    "safety_refusal",
    SafetyRefusal,
    message,
    "Review the safety boundary and explicitly authorize only this invocation.",
    None,
  )
}

fn incomplete_archive_hint() -> String {
  "The release archive is incomplete; re-extract it and verify checksums.sha256."
}

pub fn agent_beam_unavailable(bundled: Bool) -> CliError {
  CliError(
    "agent_beam_unavailable",
    CommandFailed,
    "The injected agent BEAM is unavailable, so no capture can be armed.",
    case bundled {
      True -> incomplete_archive_hint()
      False ->
        "Run the CLI through 'mise run beamtrace -- <command>' or scripts/beamtrace.ps1, or set BEAMTRACE_AGENT_BEAM to .build/agent-runtime/beamtrace_agent.beam."
    },
    None,
  )
}

pub fn web_assets_unavailable(bundled: Bool) -> CliError {
  CliError(
    "web_assets_unavailable",
    CommandFailed,
    "The Web workspace assets are unavailable.",
    case bundled {
      True -> incomplete_archive_hint()
      False ->
        "Run 'mise run web:build' or set BEAMTRACE_WEB_ROOT to packages/beamtrace_web/dist."
    },
    None,
  )
}

pub fn command_not_found(program: String) -> CliError {
  CliError(
    "command_not_found",
    CommandFailed,
    "The command '" <> program <> "' was not found on PATH.",
    "record runs your application on the Erlang toolchain from PATH; the bundled runtime only runs BeamTrace and 'beamtrace demo'. Install Erlang/OTP 27-29 or add it to PATH.",
    None,
  )
}

pub fn archive_not_found(path: String) -> CliError {
  CliError(
    "archive_not_found",
    CommandFailed,
    "No file exists at '" <> path <> "'.",
    "Check the archive path; generated names look like beamtrace-YYYYMMDDTHHMMSSZ.beamtrace.",
    None,
  )
}

pub fn output_exists(path: String) -> CliError {
  CliError(
    "output_exists",
    CommandFailed,
    "The output path '" <> path <> "' already exists.",
    "Choose another path or pass --force with an explicit --out path.",
    None,
  )
}

pub fn child_start_failed(reason: String) -> CliError {
  CliError(
    "child_start_failed",
    CommandFailed,
    "The application command could not be started: " <> reason <> ".",
    "Check the command after '--' and the toolchain on PATH.",
    None,
  )
}

pub fn child_crashed(status: Int) -> CliError {
  CliError(
    "child_crashed",
    CommandFailed,
    "The application VM exited during boot with status "
      <> int.to_string(status)
      <> ".",
    "Read the child output tail; fix the boot error and record again.",
    None,
  )
}

pub fn invalid_trace_graph(reason: String) -> CliError {
  CliError(
    "invalid_trace_graph",
    CommandFailed,
    "The archive causal graph cannot be compared: " <> reason <> ".",
    "Run 'beamtrace validate' on the archive and capture again if it is corrupt.",
    None,
  )
}

pub fn capture_incomplete() -> CliError {
  CliError(
    "capture_incomplete",
    CommandFailed,
    "The armed operation did not produce a complete capture.",
    "Confirm the selected MFA is invoked once before the capture window ends.",
    None,
  )
}

pub fn target_unavailable() -> CliError {
  CliError(
    "target_unavailable",
    CommandFailed,
    "The application did not start a reachable BEAM node within 10 s.",
    "Check the child command, distribution flags, node name, and cookie.",
    None,
  )
}

pub fn capture_arm_timeout() -> CliError {
  CliError(
    "capture_arm_timeout",
    CommandFailed,
    "The target did not confirm arming within 5 s.",
    "Run 'beamtrace doctor' and verify the selected MFA exists on the target.",
    None,
  )
}

pub fn system_tracer_occupied() -> CliError {
  CliError(
    "system_tracer_occupied",
    SafetyRefusal,
    "Another system tracer owns the target VM; BeamTrace did not replace it.",
    "Stop that tracer, or use 'beamtrace attach <node> --web' for bounded Live sampling.",
    None,
  )
}

pub fn trigger_timeout() -> CliError {
  CliError(
    "trigger_timeout",
    CommandFailed,
    "The trigger MFA was not called before the capture window ended.",
    "Perform the operation while the capture is armed, or raise --capture-window.",
    None,
  )
}

pub fn target_unreachable(reason: String) -> CliError {
  CliError(
    "target_unreachable",
    CommandFailed,
    "The target node could not be reached over Erlang distribution.",
    "Check EPMD, the node name domain (short or long), hosts entries, and that the cookie file matches the target.",
    None,
  )
  |> with_detail(reason)
}

pub fn capture_failed(reason: String) -> CliError {
  CliError(
    "capture_failed",
    CommandFailed,
    "The capture failed.",
    "Run 'beamtrace doctor', then retry with the same trigger.",
    None,
  )
  |> with_detail(reason)
}

pub fn unsupported_json_command() -> CliError {
  CliError(
    "unsupported_json_command",
    CommandFailed,
    "This command cannot produce a finite JSON result.",
    "Use --no-ui where available or omit --json.",
    None,
  )
}

pub fn configuration_create_failed(reason: String) -> CliError {
  CliError(
    "configuration_create_failed",
    CommandFailed,
    "The project configuration file could not be created.",
    "Check directory permissions and whether beamtrace.toml already exists.",
    None,
  )
  |> with_detail(reason)
}

pub fn invalid_configuration(reason: String) -> CliError {
  CliError(
    "invalid_configuration",
    CommandFailed,
    "The beamtrace.toml project configuration is invalid.",
    "Fix the reported field, then run 'beamtrace config check'.",
    None,
  )
  |> with_detail(reason)
}

pub fn cookie_unavailable(reason: String) -> CliError {
  CliError(
    "cookie_unavailable",
    CommandFailed,
    "The distribution cookie could not be prepared.",
    "Pass --cookie-file with a private readable file or set BEAMTRACE_COOKIE.",
    None,
  )
  |> with_detail(reason)
}

pub fn export_conversion_failed() -> CliError {
  CliError(
    "export_conversion_failed",
    CommandFailed,
    "The archive could not be represented in the requested format.",
    "For OTLP, pass --otlp-anchor-now only when an explicit wall-clock anchor is acceptable.",
    None,
  )
}

pub fn export_write_failed(path: String) -> CliError {
  CliError(
    "export_write_failed",
    CommandFailed,
    "The exported artifact could not be written to '" <> path <> "'.",
    "Check the destination directory permissions and free space.",
    None,
  )
}

pub fn demo_fixture_unavailable(bundled: Bool) -> CliError {
  CliError(
    "demo_fixture_unavailable",
    CommandFailed,
    "The bundled demo fixture could not be prepared.",
    case bundled {
      True -> incomplete_archive_hint()
      False -> "Run 'beamtrace doctor' to verify the demo runtime assets."
    },
    None,
  )
}

pub fn invalid_paths() -> CliError {
  CliError(
    "invalid_paths",
    CommandFailed,
    "Compare requires 2 to 20 distinct .beamtrace files.",
    "Pass each archive path once; see 'beamtrace help compare'.",
    None,
  )
}

pub fn trace_load_failed(path: String) -> CliError {
  CliError(
    "trace_load_failed",
    CommandFailed,
    "The archive '" <> path <> "' could not be loaded.",
    "Run 'beamtrace validate " <> path <> "' for details.",
    None,
  )
}

pub fn target_node_unavailable(detail: String) -> CliError {
  CliError(
    "target_node_unavailable",
    CommandFailed,
    "A target node could not be selected.",
    "Pass --node explicitly or check the local hostname configuration.",
    None,
  )
  |> with_detail(detail)
}

pub fn capture_arm_failed() -> CliError {
  CliError(
    "capture_arm_failed",
    CommandFailed,
    "The capture could not be armed.",
    "Verify that no capture is active and that the MFA exists on the target.",
    None,
  )
}

pub fn child_release_failed() -> CliError {
  CliError(
    "child_release_failed",
    CommandFailed,
    "The application command could not be released after arming.",
    "Retry after confirming the child command can start normally.",
    None,
  )
}

pub fn child_shutdown_failed() -> CliError {
  CliError(
    "child_shutdown_failed",
    CommandFailed,
    "The application command could not leave the capture shutdown gate.",
    "Run the command directly and check its shutdown behavior.",
    None,
  )
}

pub fn child_wait_failed() -> CliError {
  CliError(
    "child_wait_failed",
    CommandFailed,
    "The application command did not finish cleanly.",
    "Inspect the application command separately, then retry record.",
    None,
  )
}

/// Translate a capture or record reason into a catalogue entry.
pub fn from_capture_reason(reason: String) -> CliError {
  let not_found = "executable_not_found: "
  case reason {
    "arm_timeout" -> capture_arm_timeout()
    "node_start_timeout" -> target_unavailable()
    "system_tracer_occupied" -> system_tracer_occupied()
    "trigger_timeout" -> trigger_timeout()
    "agent_beam_unavailable" -> agent_beam_unavailable(bundled_runtime())
    _ ->
      case string.starts_with(reason, not_found) {
        True ->
          command_not_found(string.drop_start(reason, string.length(not_found)))
        False ->
          case
            string.contains(reason, "nodedown")
            || string.contains(reason, "distribution_start_failed")
            || string.contains(reason, "badrpc")
          {
            True -> target_unreachable(reason)
            False -> capture_failed(reason)
          }
      }
  }
}

pub fn from_storage(error: storage.StorageError, path: String) -> CliError {
  let hint =
    "Check the archive path and run capture again if integrity cannot be restored."
  case error {
    storage.InvalidContainer ->
      CliError(
        "invalid_container",
        CommandFailed,
        "The file is not a valid BeamTrace archive.",
        hint,
        None,
      )
    storage.UnsafeEntry(entry) ->
      CliError(
        "unsafe_entry",
        CommandFailed,
        "The archive contains an unsafe entry '" <> entry <> "'.",
        hint,
        None,
      )
    storage.DuplicateEntry(entry) ->
      CliError(
        "duplicate_entry",
        CommandFailed,
        "The archive contains a duplicate entry '" <> entry <> "'.",
        hint,
        None,
      )
    storage.ZipBomb ->
      CliError(
        "zip_bomb",
        CommandFailed,
        "The archive exceeds safe size or compression limits.",
        hint,
        None,
      )
    storage.ChecksumMismatch ->
      CliError(
        "checksum_mismatch",
        CommandFailed,
        "An archive checksum does not match.",
        hint,
        None,
      )
    storage.InvalidWindow ->
      CliError(
        "invalid_window",
        CommandFailed,
        "The requested event window is invalid.",
        "Use a start of 0 or more and a limit between 1 and 1000.",
        None,
      )
    storage.InvalidSearch ->
      CliError(
        "invalid_search",
        CommandFailed,
        "The requested search is invalid.",
        "Use a query of at most 256 characters.",
        None,
      )
    storage.InvalidGraph(_) ->
      CliError(
        "invalid_graph",
        CommandFailed,
        "The archive causal graph is invalid.",
        hint,
        None,
      )
    storage.MigrationRequiresDistinctOutput ->
      CliError(
        "migration_output_conflict",
        CommandFailed,
        "Migration output must be different from the source.",
        "Pass --output with a path that differs from the input archive.",
        None,
      )
    storage.CodecError(_) ->
      CliError(
        "schema_error",
        CommandFailed,
        "The archive contains invalid schema data.",
        hint,
        None,
      )
    storage.IoError("destination_exists") -> output_exists(path)
    storage.IoError("enoent") -> archive_not_found(path)
    storage.IoError(reason) ->
      CliError(
        "io_error",
        CommandFailed,
        "The archive could not be read or written.",
        "Check file permissions and free space, then retry.",
        None,
      )
      |> with_detail(reason)
  }
}

@external(erlang, "beamtrace_cli_ffi", "bundled_runtime")
fn bundled_runtime() -> Bool

pub fn classify_child_output(output: String) -> Option(String) {
  case
    string.contains(output, "Crash dump is being written")
    || string.contains(output, "crash dump slogan:")
    || string.contains(output, "Runtime terminating during boot")
  {
    True -> Some("child_crashed")
    False -> None
  }
}

/// Every catalogue entry with representative arguments.
pub fn all() -> List(CliError) {
  [
    invalid_arguments("unknown command 'x'"),
    command_failed("the command failed"),
    capture_integrity("capture integrity issues present"),
    safety_refusal("the operation was refused"),
    legacy("differences found", 1),
    agent_beam_unavailable(True),
    web_assets_unavailable(True),
    command_not_found("erl"),
    archive_not_found("trace.beamtrace"),
    output_exists("trace.beamtrace"),
    child_start_failed("reason"),
    child_crashed(1),
    target_unavailable(),
    invalid_trace_graph("duplicate event id 'x'"),
    capture_incomplete(),
    capture_arm_timeout(),
    system_tracer_occupied(),
    trigger_timeout(),
    target_unreachable("nodedown"),
    capture_failed("reason"),
    unsupported_json_command(),
    configuration_create_failed("eacces"),
    invalid_configuration("invalid value"),
    cookie_unavailable("enoent"),
    export_conversion_failed(),
    export_write_failed("trace.html"),
    demo_fixture_unavailable(True),
    invalid_paths(),
    trace_load_failed("trace.beamtrace"),
    target_node_unavailable("no hostname"),
    capture_arm_failed(),
    child_release_failed(),
    child_shutdown_failed(),
    child_wait_failed(),
    from_storage(storage.InvalidContainer, "x"),
    from_storage(storage.UnsafeEntry("x"), "x"),
    from_storage(storage.DuplicateEntry("x"), "x"),
    from_storage(storage.ZipBomb, "x"),
    from_storage(storage.ChecksumMismatch, "x"),
    from_storage(storage.InvalidWindow, "x"),
    from_storage(storage.InvalidSearch, "x"),
    from_storage(storage.InvalidGraph("x"), "x"),
    from_storage(storage.MigrationRequiresDistinctOutput, "x"),
    from_storage(storage.CodecError("x"), "x"),
    from_storage(storage.IoError("eacces"), "x"),
  ]
}

pub fn codes() -> List(String) {
  all()
  |> list.map(fn(error) { error.code })
  |> list.unique
  |> list.sort(string.compare)
}
