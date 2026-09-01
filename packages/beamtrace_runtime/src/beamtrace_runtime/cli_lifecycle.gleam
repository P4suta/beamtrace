// SPDX-License-Identifier: Apache-2.0 OR MIT
import argv
import beamtrace/codec
import beamtrace/dag
import beamtrace/diff
import beamtrace/stats
import beamtrace/types
import beamtrace_runtime/api
import beamtrace_runtime/capture
import beamtrace_runtime/capture_session
import beamtrace_runtime/cli
import beamtrace_runtime/cli_errors
import beamtrace_runtime/cli_spec
import beamtrace_runtime/command
import beamtrace_runtime/compare_workspace
import beamtrace_runtime/export
import beamtrace_runtime/internal/version as runtime_version
import beamtrace_runtime/local_auth
import beamtrace_runtime/mcp
import beamtrace_runtime/oidc_discovery
import beamtrace_runtime/project_config
import beamtrace_runtime/raw_grant_file
import beamtrace_runtime/record_process
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_client
import beamtrace_runtime/relay_session
import beamtrace_runtime/server
import beamtrace_runtime/storage
import beamtrace_runtime/team_config
import beamtrace_runtime/team_tui
import beamtrace_runtime/tui_driver
import beamtrace_tui
import beamtrace_tui/model as tui_model
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const version = runtime_version.current

pub fn main() {
  let arguments = argv.load().arguments
  let parsed = case project_config.prepare(arguments) {
    Ok(arguments) ->
      case approve_seq_trace_if_needed(arguments) {
        Ok(arguments) -> cli.parse(arguments)
        Error(error) -> Error(error)
      }
    Error(message) -> Error(cli.ParseError(message, 2))
  }
  let code = case parsed {
    Ok(command) -> run(command)
    Error(cli.ParseError(message, exit_code)) -> {
      let error = case exit_code {
        4 -> cli_errors.safety_refusal(message)
        _ -> cli_errors.invalid_arguments(message)
      }
      case cli.json_requested(arguments) {
        True -> {
          let command = cli.invoked_command(arguments)
          let invoked = case command {
            "unknown" -> cli.invoked_token(arguments)
            _ -> None
          }
          emit_json_parse_failure(command, invoked, error)
        }
        False -> {
          let _ = fail_with(error)
          Nil
        }
      }
      cli_errors.exit_code(error)
    }
  }
  halt(code)
}

fn approve_seq_trace_if_needed(
  arguments: List(String),
) -> Result(List(String), cli.ParseError) {
  case cli.requires_seq_trace_ack(arguments), terminal_interactive() {
    False, _ -> Ok(arguments)
    True, False -> Ok(arguments)
    True, True ->
      case confirm_seq_trace() {
        True -> Ok(cli.add_seq_trace_ack(arguments))
        False ->
          Error(cli.ParseError(
            "capture cancelled because the seq_trace reset was not approved",
            4,
          ))
      }
  }
}

fn run(command_: cli.Command) -> Int {
  case command_ {
    cli.Json(command) -> run_json(command)
    cli.Force(command) -> run_force(command)
    cli.RecordUi(command, display) ->
      run_record_ui_command(command, display, False)
    cli.Guide -> {
      io.println(cli_spec.short_guide())
      0
    }
    cli.Help -> {
      io.println(cli_spec.root_help())
      0
    }
    cli.CommandHelp("errors") -> {
      io.println(error_catalogue_help())
      0
    }
    cli.CommandHelp(name) -> {
      case cli_spec.command_help(name) {
        Some(help) -> io.println(help)
        None -> Nil
      }
      0
    }
    cli.Completion(shell) -> {
      case cli_spec.completion(shell) {
        Some(script) -> io.print(script)
        None -> Nil
      }
      0
    }
    cli.Version -> {
      io.println("beamtrace " <> version)
      0
    }
    cli.Init ->
      case project_config.init() {
        Ok(path) -> {
          io.println("Created " <> path)
          0
        }
        Error(error) -> fail(error, 2)
      }
    cli.ConfigCheck ->
      case project_config.check() {
        Ok(summary) -> {
          io.println(summary)
          0
        }
        Error(error) -> fail("configuration invalid: " <> error, 2)
      }
    cli.Doctor(json) -> {
      case project_config.validate_current() {
        Error(error) -> fail("configuration invalid: " <> error, 2)
        Ok(configuration) -> {
          let #(profile_status, cookie_files) = case configuration {
            Some(configuration) -> #(
              "valid",
              project_config.cookie_files(configuration),
            )
            None -> #("not_found", [])
          }
          io.print(doctor(json, profile_status, cookie_files))
          0
        }
      }
    }
    cli.Capture(
      node,
      trigger,
      where_aql,
      out,
      cookie_file,
      max_roots,
      preset,
      window_s,
    ) ->
      run_capture(
        node,
        trigger,
        where_aql,
        out,
        cookie_file,
        max_roots,
        preset,
        window_s,
        False,
      )
    cli.Attach(node, mode, cookie_file, port) ->
      run_attach(node, mode, cookie_file, port)
    cli.Open(path, mode, port) -> run_open(path, mode, port)
    cli.Compare(left, right) -> run_compare(left, right)
    cli.CompareMany(paths, display, port) ->
      run_compare_many(paths, display, port)
    cli.Export(path, format, anchor_now) -> run_export(path, format, anchor_now)
    cli.Validate(path, json) -> run_validate(path, json)
    cli.Migrate(path, output) -> run_migrate(path, output)
    cli.Record(
      node,
      trigger,
      where_aql,
      out,
      cookie_file,
      max_roots,
      preset,
      child,
      window_s,
    ) -> {
      let display = case terminal_interactive() {
        True -> cli.RecordWeb
        False -> cli.RecordNoUi
      }
      run_record_ui_command(
        cli.Record(
          node,
          trigger,
          where_aql,
          out,
          cookie_file,
          max_roots,
          preset,
          child,
          window_s,
        ),
        display,
        False,
      )
    }
    cli.Serve(port) -> run_serve(port, terminal_interactive())
    cli.ServeNoOpen(port) -> run_serve(port, False)
    cli.Demo(mode, out, port) -> run_demo(mode, out, port)
    cli.Relay(hub_url, enrollment_token, target) ->
      run_relay(hub_url, enrollment_token, target)
    cli.Tui(server_url, session_cookie_file) -> {
      let target = case server_url {
        Some(value) -> value
        None -> "http://127.0.0.1:4040"
      }
      case session_cookie_file {
        None -> {
          beamtrace_tui.run_remote(target)
          0
        }
        Some(path) ->
          case team_tui.load_traces(target, path) {
            Ok(traces) -> {
              beamtrace_tui.run_remote_with_traces(target, traces)
              0
            }
            Error(error) -> fail("could not load Team traces: " <> error, 2)
          }
      }
    }
    cli.Mcp -> {
      mcp.run()
      0
    }
  }
}

fn run_force(command_: cli.Command) -> Int {
  case command_ {
    cli.RecordUi(command, display) ->
      run_record_ui_command(command, display, True)
    cli.Capture(
      node,
      trigger,
      where_aql,
      out,
      cookie_file,
      max_roots,
      preset,
      window_s,
    ) ->
      run_capture(
        node,
        trigger,
        where_aql,
        out,
        cookie_file,
        max_roots,
        preset,
        window_s,
        True,
      )
    cli.Record(..) -> {
      let display = case terminal_interactive() {
        True -> cli.RecordWeb
        False -> cli.RecordNoUi
      }
      run_record_ui_command(command_, display, True)
    }
    command -> run(command)
  }
}

fn run_record_ui_command(
  command_: cli.Command,
  display: cli.RecordDisplay,
  force: Bool,
) -> Int {
  case command_ {
    cli.Record(
      node,
      trigger,
      where_aql,
      out,
      cookie_file,
      max_roots,
      preset,
      child,
      window_s,
    ) -> {
      let output = case out == "" {
        True -> default_archive_path()
        False -> out
      }
      let recorded =
        run_record(
          node,
          trigger,
          where_aql,
          output,
          cookie_file,
          max_roots,
          preset,
          child,
          [],
          window_s,
          force,
        )
      let archive_saved = record_wrote_archive(recorded)
      case archive_saved, display, storage.validate(output) {
        False, _, _ | _, cli.RecordNoUi, _ | _, _, Error(_) -> recorded
        True, cli.RecordWeb, Ok(_) -> {
          let opened = run_open(output, cli.Web, 0)
          case opened {
            0 -> recorded
            code -> code
          }
        }
        True, cli.RecordWebNoOpen, Ok(_) -> {
          let opened = run_open(output, cli.WebNoOpen, 0)
          case opened {
            0 -> recorded
            code -> code
          }
        }
        True, cli.RecordTui, Ok(_) -> {
          let opened = run_open(output, cli.TuiMode, 0)
          case opened {
            0 -> recorded
            code -> code
          }
        }
      }
    }
    _ -> run(command_)
  }
}

fn run_json(command_: cli.Command) -> Int {
  run_json_with_force(command_, False)
}

fn run_json_with_force(command_: cli.Command, force: Bool) -> Int {
  case command_ {
    cli.Force(command) -> run_json_with_force(command, True)
    cli.RecordUi(command, _) -> run_json_with_force(command, force)
    cli.Capture(
      node,
      trigger,
      where_aql,
      out,
      cookie_file,
      max_roots,
      preset,
      window_s,
    ) ->
      run_capture_json(
        node,
        trigger,
        where_aql,
        out,
        cookie_file,
        max_roots,
        preset,
        window_s,
        force,
      )
    cli.Record(
      node,
      trigger,
      where_aql,
      out,
      cookie_file,
      max_roots,
      preset,
      child,
      window_s,
    ) ->
      run_record_json(
        "record",
        node,
        trigger,
        where_aql,
        out,
        cookie_file,
        max_roots,
        preset,
        child,
        [],
        window_s,
        force,
        False,
      )
    cli.Demo(cli.DemoNoUi, out, _) -> run_demo_json(out)
    cli.Export(path, format, anchor_now) ->
      run_export_json(path, format, anchor_now)
    cli.Validate(path, _) -> run_validate(path, True)
    cli.Migrate(path, output) -> run_migrate_json(path, output)
    cli.Compare(left, right) -> run_compare_json([left, right])
    cli.CompareMany(paths, _, _) -> run_compare_json(paths)
    cli.Init -> run_init_json()
    cli.ConfigCheck -> run_config_check_json()
    cli.Version -> {
      emit_json_success(
        "version",
        json.object([#("version", json.string(version))]),
      )
      0
    }
    cli.Doctor(_) -> run_doctor_json()
    // The parser rejects JSON for interactive and long-running commands.
    command -> {
      emit_json_error(
        "unknown",
        2,
        "unsupported_json_command",
        "This command cannot produce a finite JSON result.",
        "Use --no-ui where available or omit --json.",
      )
      let _ = command
      2
    }
  }
}

fn run_init_json() -> Int {
  case project_config.init() {
    Ok(path) -> {
      emit_json_success("init", json.object(path_artifact(path)))
      0
    }
    Error(_) -> {
      emit_json_error(
        "init",
        2,
        "configuration_create_failed",
        "BeamTrace could not create the project configuration.",
        "Check directory permissions and whether beamtrace.toml already exists.",
      )
      2
    }
  }
}

fn run_config_check_json() -> Int {
  case project_config.check() {
    Ok(summary) -> {
      emit_json_success(
        "config",
        json.object([#("summary", json.string(summary))]),
      )
      0
    }
    Error(_) -> {
      emit_json_error(
        "config",
        2,
        "invalid_configuration",
        "BeamTrace project configuration is invalid.",
        "Run 'beamtrace config check' without --json for the field-level diagnostic.",
      )
      2
    }
  }
}

fn run_capture_json(
  node: String,
  trigger: cli.Mfa,
  where_aql: Option(String),
  out: String,
  cookie_file: Option(String),
  max_roots: Int,
  preset: types.Preset,
  window_s: Int,
  force: Bool,
) -> Int {
  let output = case out == "" {
    True -> default_archive_path()
    False -> out
  }
  use Nil <- json_output_or_exit("capture", output, force)
  use Nil <- json_error_or_exit("capture", preflight_agent())
  case read_cookie(cookie_file) {
    Error(_) -> {
      emit_json_error(
        "capture",
        2,
        "cookie_unavailable",
        "The distribution cookie could not be read.",
        "Pass --cookie-file with a private readable file or configure BEAMTRACE_COOKIE.",
      )
      2
    }
    Ok(cookie) -> {
      let cli.Mfa(module, function, arity) = trigger
      let nodes = string.split(node, on: ",") |> list.map(string.trim)
      let spec =
        types.CaptureSpec(
          nodes: nodes,
          trigger: types.Mfa(module, function, arity),
          where_aql: where_aql,
          privacy: types.Metadata,
          budget: types.TraceBudget(
            ..types.default_budget(),
            max_roots: max_roots,
            max_duration_ms: window_s * 1000,
          ),
          preset: preset,
        )
      case capture.execute(spec, cookie) {
        Error(error) -> {
          let failure = cli_errors.from_capture_reason(error)
          emit_json_failure("capture", failure)
          cli_errors.exit_code(failure)
        }
        Ok(result) -> {
          let manifest =
            codec.Manifest(
              schema_version: codec.schema_version,
              tool_version: version,
              capture_id: capture_id(),
              nodes: nodes,
              outcome: result.outcome,
              privacy: types.Metadata,
            )
          let saved = case force {
            True ->
              storage.save_with_clocks(
                output,
                manifest,
                result.events,
                result.clocks,
              )
            False ->
              storage.save_exclusive_with_clocks(
                output,
                manifest,
                result.events,
                result.clocks,
              )
          }
          case saved {
            Error(error) -> {
              emit_json_failure(
                "capture",
                cli_errors.from_storage(error, output),
              )
              2
            }
            Ok(Nil) -> {
              let exit_code = capture.exit_code(result.outcome)
              emit_json_outcome_result(
                "capture",
                exit_code,
                Some(
                  json.object(
                    list.append(path_artifact(output), [
                      #("event_count", json.int(list.length(result.events))),
                    ]),
                  ),
                ),
                codec.outcome_json(result.outcome),
              )
              exit_code
            }
          }
        }
      }
    }
  }
}

fn run_export_json(
  path: String,
  format: cli.ExportFormat,
  anchor_now: Bool,
) -> Int {
  case storage.load(path) {
    Error(error) -> {
      emit_json_failure("export", cli_errors.from_storage(error, path))
      2
    }
    Ok(archive) -> {
      let output = command.export_path(path, format)
      let content = case format {
        cli.Html -> Ok(export.html(archive, include_raw: False))
        cli.Jsonl -> Ok(export.jsonl(archive, include_raw: False))
        cli.Mermaid -> Ok(export.mermaid(archive))
        cli.Otlp ->
          export.otlp(archive, include_raw: False, anchor_now: anchor_now)
      }
      case content {
        Error(_) -> {
          emit_json_error(
            "export",
            2,
            "export_conversion_failed",
            "The archive could not be represented in the requested format.",
            "For OTLP, pass --otlp-anchor-now only when an explicit wall-clock anchor is acceptable.",
          )
          2
        }
        Ok(content) ->
          case write_text(output, content) {
            Error(_) -> {
              emit_json_error(
                "export",
                2,
                "export_write_failed",
                "The exported artifact could not be written.",
                "Check the destination directory permissions and free space.",
              )
              2
            }
            Ok(Nil) -> {
              emit_json_success(
                "export",
                json.object(
                  list.append(path_artifact(output), [
                    #("format", json.string(export_format_name(format))),
                  ]),
                ),
              )
              0
            }
          }
      }
    }
  }
}

fn export_format_name(format: cli.ExportFormat) -> String {
  case format {
    cli.Html -> "html"
    cli.Jsonl -> "jsonl"
    cli.Mermaid -> "mermaid"
    cli.Otlp -> "otlp"
  }
}

fn run_migrate_json(path: String, output: String) -> Int {
  case storage.migrate(path, output, version) {
    Ok(Nil) -> {
      emit_json_success(
        "migrate",
        json.object([
          #("source", json.string(path)),
          #("path", json.string(output)),
          #("absolute_path", json.string(absolute_path(output))),
          #("schema_version", json.int(2)),
        ]),
      )
      0
    }
    Error(error) -> {
      emit_json_failure("migrate", migrate_error(error, path, output))
      2
    }
  }
}

type MachineRecord {
  MachineRecord(
    event_count: Int,
    outcome: types.CaptureOutcome,
    child_status: Int,
  )
}

type MachineRecordError =
  cli_errors.CliError

const demo_staged_modules = ["beamtrace_demo_fixture"]

fn run_demo_json(out: String) -> Int {
  case record_process.demo_command() {
    Error(_) -> {
      emit_json_error(
        "demo",
        2,
        "demo_fixture_unavailable",
        "The bundled demo command could not be prepared.",
        "Run 'beamtrace doctor' to verify the native distribution assets.",
      )
      2
    }
    Ok(child) -> {
      let temporary = out == ""
      let output = case temporary {
        True -> temporary_archive_path()
        False -> out
      }
      run_record_json(
        "demo",
        None,
        cli.Mfa("beamtrace_demo_fixture", "run", 0),
        None,
        output,
        None,
        1,
        types.Generic,
        child,
        demo_staged_modules,
        cli.default_window_s,
        False,
        temporary,
      )
    }
  }
}

fn run_record_json(
  command_name: String,
  requested_node: Option(String),
  trigger: cli.Mfa,
  where_aql: Option(String),
  out: String,
  cookie_file: Option(String),
  max_roots: Int,
  preset: types.Preset,
  child: List(String),
  staged_modules: List(String),
  window_s: Int,
  force: Bool,
  delete_after: Bool,
) -> Int {
  let output = case out == "" {
    True -> default_archive_path()
    False -> out
  }
  let result =
    execute_record_machine(
      requested_node,
      trigger,
      where_aql,
      output,
      cookie_file,
      max_roots,
      preset,
      child,
      staged_modules,
      window_s,
      force,
    )
  let exit_code = case result {
    Error(error) -> {
      emit_json_failure(command_name, error)
      cli_errors.exit_code(error)
    }
    Ok(recorded) -> {
      let outcome_code = capture.exit_code(recorded.outcome)
      let exit_code = case recorded.child_status, outcome_code {
        0, code -> code
        _, _ -> 1
      }
      emit_json_outcome_result(
        command_name,
        exit_code,
        Some(
          json.object(
            list.append(path_artifact(output), [
              #("retained", json.bool(!delete_after)),
              #("event_count", json.int(recorded.event_count)),
              #("child_exit_code", json.int(recorded.child_status)),
            ]),
          ),
        ),
        codec.outcome_json(recorded.outcome),
      )
      exit_code
    }
  }
  case delete_after, result {
    True, Ok(_) -> delete_file(output)
    _, _ -> Nil
  }
  exit_code
}

fn execute_record_machine(
  requested_node: Option(String),
  trigger: cli.Mfa,
  where_aql: Option(String),
  output: String,
  cookie_file: Option(String),
  max_roots: Int,
  preset: types.Preset,
  child: List(String),
  staged_modules: List(String),
  window_s: Int,
  force: Bool,
) -> Result(MachineRecord, MachineRecordError) {
  use Nil <- machine_result(
    output_available(output, force),
    cli_errors.output_exists(output),
  )
  use Nil <- machine_result_error(preflight_agent())
  use cookie <- machine_result(
    read_record_cookie(cookie_file),
    cli_errors.CliError(
      "cookie_unavailable",
      cli_errors.CommandFailed,
      "The record distribution cookie could not be prepared.",
      "Pass a private --cookie-file or allow BeamTrace to create an ephemeral cookie.",
      None,
    ),
  )
  use node <- machine_result(
    case requested_node {
      Some(node) -> Ok(node)
      None -> record_process.auto_node()
    },
    cli_errors.CliError(
      "target_node_unavailable",
      cli_errors.CommandFailed,
      "A target node name could not be selected.",
      "Pass --node explicitly or check the local hostname configuration.",
      None,
    ),
  )
  let nodes = string.split(node, on: ",") |> list.map(string.trim)
  case nodes {
    [] ->
      Error(cli_errors.CliError(
        "target_node_unavailable",
        cli_errors.CommandFailed,
        "Record requires at least one target node.",
        "Pass a non-empty --node value.",
        None,
      ))
    [root, ..] -> {
      let cli.Mfa(trigger_module, _, _) = trigger
      case
        record_process.start_staged(
          child,
          root,
          cookie,
          trigger_module,
          staged_modules,
        )
      {
        Error(reason) -> Error(child_start_error(reason))
        Ok(handle) ->
          case capture.wait_until_available(root, cookie, 10_000) {
            Error(reason) -> Error(record_start_error(handle, reason))
            Ok(Nil) -> {
              let store = capture_session.new(nodes, cookie)
              let result =
                execute_record_machine_session(
                  store,
                  handle,
                  nodes,
                  cookie,
                  trigger,
                  where_aql,
                  output,
                  max_roots,
                  preset,
                  window_s,
                  force,
                )
              capture_session.close(store)
              result
            }
          }
      }
    }
  }
}

fn execute_record_machine_session(
  store: capture_session.Store,
  handle: record_process.Handle,
  nodes: List(String),
  cookie: String,
  trigger: cli.Mfa,
  where_aql: Option(String),
  output: String,
  max_roots: Int,
  preset: types.Preset,
  window_s: Int,
  force: Bool,
) -> Result(MachineRecord, MachineRecordError) {
  let cli.Mfa(module, function, arity) = trigger
  let spec =
    capture_session.ArmSpec(
      trigger: types.Mfa(module, function, arity),
      where_aql: where_aql,
      capture_window_ms: window_s * 1000,
      drain_timeout_ms: 10_000,
      budget: capture.default_budget(),
      max_roots: max_roots,
      preset: preset,
    )
  case capture_session.arm(store, spec), nodes {
    Error(_), _ | _, [] -> {
      record_process.stop(handle)
      Error(cli_errors.CliError(
        "capture_arm_failed",
        cli_errors.CommandFailed,
        "The capture could not be armed.",
        "Verify that no capture is active and that the MFA exists on the target.",
        None,
      ))
    }
    Ok(Nil), [root, ..] ->
      case capture.wait_until_armed(root, cookie, 5000) {
        Error(error) -> {
          let failure = arm_failure(store, error)
          let _ = capture_session.cancel(store)
          record_process.stop(handle)
          Error(failure)
        }
        Ok(Nil) ->
          case record_process.release(handle) {
            Error(_) -> {
              let _ = capture_session.cancel(store)
              record_process.stop(handle)
              Error(cli_errors.CliError(
                "child_release_failed",
                cli_errors.CommandFailed,
                "The application command could not be released after arming.",
                "Retry after confirming the child command can start normally.",
                None,
              ))
            }
            Ok(Nil) ->
              execute_record_machine_child(
                store,
                handle,
                nodes,
                output,
                window_s,
                force,
              )
          }
      }
  }
}

fn execute_record_machine_child(
  store: capture_session.Store,
  handle: record_process.Handle,
  nodes: List(String),
  output: String,
  window_s: Int,
  force: Bool,
) -> Result(MachineRecord, MachineRecordError) {
  case capture_session.await(store, window_s * 1000 + 5000) {
    Error(_) -> {
      let _ = capture_session.cancel(store)
      let _ = record_process.release_finish(handle)
      record_process.stop(handle)
      Error(cli_errors.CliError(
        "capture_incomplete",
        cli_errors.CommandFailed,
        "The armed operation did not produce a complete capture.",
        "Confirm the selected MFA is invoked once before the capture window ends.",
        None,
      ))
    }
    Ok(result) ->
      case record_process.release_finish(handle) {
        Error(_) -> {
          record_process.stop(handle)
          Error(cli_errors.CliError(
            "child_shutdown_failed",
            cli_errors.CommandFailed,
            "The application command could not leave the capture shutdown gate.",
            "Run the command directly and check its shutdown behavior.",
            None,
          ))
        }
        Ok(Nil) ->
          case record_process.await(handle, 86_400_000) {
            Error(_) ->
              Error(cli_errors.CliError(
                "child_wait_failed",
                cli_errors.CommandFailed,
                "The application command did not finish cleanly.",
                "Inspect the application command separately, then retry record.",
                None,
              ))
            Ok(#(child_status, _)) ->
              case save_result(output, nodes, result, types.Metadata, force) {
                Error(error) -> Error(error)
                Ok(Nil) ->
                  Ok(MachineRecord(
                    list.length(result.events),
                    result.outcome,
                    child_status,
                  ))
              }
          }
      }
  }
}

fn machine_result(
  result: Result(a, String),
  error: MachineRecordError,
  next: fn(a) -> Result(b, MachineRecordError),
) -> Result(b, MachineRecordError) {
  case result {
    Ok(value) -> next(value)
    Error(_) -> Error(error)
  }
}

fn output_available(path: String, force: Bool) -> Result(Nil, String) {
  case force || !path_exists(path) {
    True -> Ok(Nil)
    False -> Error("destination_exists")
  }
}

fn output_or_exit(path: String, force: Bool, next: fn(Nil) -> Int) -> Int {
  case output_available(path, force) {
    Ok(Nil) -> next(Nil)
    Error(_) ->
      fail(
        "the output already exists; choose another path or pass --force with an explicit --out path",
        2,
      )
  }
}

fn json_output_or_exit(
  command: String,
  path: String,
  force: Bool,
  next: fn(Nil) -> Int,
) -> Int {
  case output_available(path, force) {
    Ok(Nil) -> next(Nil)
    Error(_) -> {
      emit_json_error(
        command,
        2,
        "output_exists",
        "The requested output path already exists.",
        "Choose another path or pass --force with an explicit --out path.",
      )
      2
    }
  }
}

fn run_doctor_json() -> Int {
  case project_config.validate_current() {
    Error(_) -> {
      emit_json_error(
        "doctor",
        2,
        "invalid_configuration",
        "BeamTrace project configuration is invalid.",
        "Run 'beamtrace config check' for the exact field to fix.",
      )
      2
    }
    Ok(configuration) -> {
      let #(profile_status, cookie_files) = case configuration {
        Some(configuration) -> #(
          "valid",
          project_config.cookie_files(configuration),
        )
        None -> #("not_found", [])
      }
      let report = string.trim(doctor(True, profile_status, cookie_files))
      emit_json_success(
        "doctor",
        json.object([
          #("report", json.string(report)),
          #("checks", doctor_checks(report)),
        ]),
      )
      0
    }
  }
}

/// Structured view of the doctor report: each boolean check with a hint
/// for the ones that fail.
fn doctor_checks(report: String) -> json.Json {
  let fields = case
    json.parse(report, decode.dict(decode.string, decode.dynamic))
  {
    Ok(fields) -> fields
    Error(_) -> dict.new()
  }
  let check = fn(name: String, hint: String) {
    let ok = case dict.get(fields, name) {
      Ok(value) ->
        case decode.run(value, decode.bool) {
          Ok(flag) -> flag
          Error(_) -> False
        }
      Error(_) -> False
    }
    #(
      name,
      json.object([
        #("ok", json.bool(ok)),
        ..case ok {
          True -> []
          False -> [#("hint", json.string(hint))]
        }
      ]),
    )
  }
  let bundled = capture.bundled_runtime()
  json.object([
    check(
      "isolated_trace_session",
      "Install Erlang/OTP 27 or newer; exact capture needs isolated trace sessions.",
    ),
    check("seq_trace", "Install an Erlang/OTP build with seq_trace support."),
    check("zip", "The Erlang zip application is required to read archives."),
    check("crypto", "The Erlang crypto application is required for checksums."),
    check("agent_beam", cli_errors.agent_beam_unavailable(bundled).hint),
    check("web_assets", cli_errors.web_assets_unavailable(bundled).hint),
    check(
      "distribution",
      "Install erl and epmd on PATH so record and capture can reach BEAM nodes.",
    ),
  ])
}

fn run_compare_json(paths: List(String)) -> Int {
  case compare_workspace.compare(paths) {
    Error(compare_workspace.InvalidPaths) -> {
      emit_json_error(
        "compare",
        2,
        "invalid_paths",
        "Compare requires 2 to 20 distinct .beamtrace files.",
        "Pass archive paths before --json.",
      )
      2
    }
    Error(compare_workspace.LoadFailed(path, _)) -> {
      emit_json_error(
        "compare",
        2,
        "trace_load_failed",
        "Could not load '" <> path <> "'.",
        "Run 'beamtrace validate " <> path <> "' first.",
      )
      2
    }
    Error(compare_workspace.InvalidTrace(path, _)) -> {
      emit_json_error(
        "compare",
        2,
        "invalid_trace_graph",
        "The causal graph in '" <> path <> "' is invalid.",
        "Run 'beamtrace validate " <> path <> "' for details.",
      )
      2
    }
    Ok(report) -> {
      let different =
        report.reports
        |> list.any(fn(item) {
          item.added > 0
          || item.removed > 0
          || item.changed > 0
          || item.ambiguity_count > 0
        })
      let exit_code = case different {
        True -> 1
        False -> 0
      }
      emit_json_result(
        "compare",
        True,
        exit_code,
        Some(
          json.object([
            #("baseline", json.string(report.baseline)),
            #("trace_count", json.int(report.run_count)),
            #(
              "runs",
              json.array(report.reports, fn(item) {
                json.object([
                  #("path", json.string(item.path)),
                  #("added", json.int(item.added)),
                  #("removed", json.int(item.removed)),
                  #("changed", json.int(item.changed)),
                  #("ambiguity_count", json.int(item.ambiguity_count)),
                ])
              }),
            ),
          ]),
        ),
        None,
      )
      exit_code
    }
  }
}

fn run_compare_many(
  paths: List(String),
  display: cli.CompareDisplay,
  port: Int,
) -> Int {
  case compare_workspace.compare(paths) {
    Error(compare_workspace.InvalidPaths) ->
      fail("compare requires 2 to 20 distinct .beamtrace files", 2)
    Error(compare_workspace.LoadFailed(path, _)) ->
      fail("could not load compare trace '" <> path <> "'", 2)
    Error(compare_workspace.InvalidTrace(path, _)) ->
      fail("invalid causal graph in compare trace '" <> path <> "'", 2)
    Ok(report) ->
      case display, paths {
        cli.CompareWeb, [baseline, ..] | cli.CompareWebNoOpen, [baseline, ..] -> {
          io.println(
            "Compare workspace: "
            <> int.to_string(report.run_count)
            <> " traces loaded.",
          )
          run_compare_server(
            baseline,
            paths,
            port,
            display == cli.CompareWeb && terminal_interactive(),
          )
        }
        cli.CompareTui, [_, ..] -> {
          beamtrace_tui.run_compare(
            report.baseline,
            report.run_count,
            list.map(report.reports, fn(item) {
              tui_model.CompareRunSummary(
                item.path,
                item.added,
                item.removed,
                item.changed,
                item.ambiguity_count,
                divergence_path_label(item.first_divergence),
              )
            }),
            list.length(report.statistics),
          )
          compare_workspace_exit(report)
        }
        _, _ -> {
          io.println(compare_workspace_summary(report))
          compare_workspace_exit(report)
        }
      }
  }
}

fn run_compare_server(
  baseline: String,
  paths: List(String),
  port: Int,
  open_browser: Bool,
) -> Int {
  case
    server.start_compare_with_browser(
      bind: "127.0.0.1",
      port: port,
      secret_key_base: random_secret(),
      static_root: Some(web_root()),
      archive_path: Some(baseline),
      paths: paths,
      open_browser: open_browser,
    )
  {
    Ok(Nil) -> 0
    Error(error) -> fail("compare server failed: " <> error, 2)
  }
}

fn divergence_path_label(divergence: Option(diff.Divergence)) -> String {
  case divergence {
    None -> ""
    Some(diff.Divergence(_, _, path)) -> string.join(path, " → ")
  }
}

fn compare_workspace_summary(report: compare_workspace.Report) -> String {
  let rows =
    report.reports
    |> list.map(fn(item) {
      item.path
      <> ": +"
      <> int.to_string(item.added)
      <> " -"
      <> int.to_string(item.removed)
      <> " ~"
      <> int.to_string(item.changed)
      <> " ?"
      <> int.to_string(item.ambiguity_count)
    })
  "Compare: "
  <> int.to_string(report.run_count)
  <> " traces; baseline "
  <> report.baseline
  <> case rows {
    [] -> ""
    _ -> "\n" <> string.join(rows, "\n")
  }
}

fn compare_workspace_exit(report: compare_workspace.Report) -> Int {
  case
    report.reports
    |> list.any(fn(item) {
      item.added > 0
      || item.removed > 0
      || item.changed > 0
      || item.ambiguity_count > 0
    })
  {
    True -> 1
    False -> 0
  }
}

fn emit_json_success(command: String, artifact: json.Json) -> Nil {
  emit_json_result(command, True, 0, Some(artifact), None)
}

fn emit_json_parse_failure(
  command: String,
  invoked: Option(String),
  error: cli_errors.CliError,
) -> Nil {
  json.object(
    list.flatten([
      [
        #("schema_version", json.int(1)),
        #("command", json.string(command)),
      ],
      case invoked {
        Some(token) -> [#("invoked", json.string(token))]
        None -> []
      },
      [
        #("ok", json.bool(False)),
        #("exit_code", json.int(cli_errors.exit_code(error))),
        #("artifact", json.null()),
        #("outcome", json.null()),
        #("error", error_json(error)),
      ],
    ]),
  )
  |> json.to_string
  |> io.println
}

fn error_json(error: cli_errors.CliError) -> json.Json {
  json.object(
    list.append(
      [
        #("code", json.string(error.code)),
        #("message", json.string(error.message)),
        #("hint", json.string(error.hint)),
      ],
      case error.detail {
        None -> []
        Some(detail) -> [#("detail", json.string(detail))]
      },
    ),
  )
}

fn emit_json_failure(command: String, error: cli_errors.CliError) -> Nil {
  emit_json_result(
    command,
    False,
    cli_errors.exit_code(error),
    None,
    Some(error_json(error)),
  )
}

fn emit_json_error(
  command: String,
  exit_code: Int,
  code: String,
  message: String,
  hint: String,
) -> Nil {
  emit_json_result(
    command,
    False,
    exit_code,
    None,
    Some(
      json.object([
        #("code", json.string(code)),
        #("message", json.string(message)),
        #("hint", json.string(hint)),
      ]),
    ),
  )
}

fn emit_json_result(
  command: String,
  ok: Bool,
  exit_code: Int,
  artifact: Option(json.Json),
  error: Option(json.Json),
) -> Nil {
  emit_json_envelope(command, ok, exit_code, artifact, None, error)
}

fn emit_json_outcome_result(
  command: String,
  exit_code: Int,
  artifact: Option(json.Json),
  outcome: json.Json,
) -> Nil {
  emit_json_envelope(command, True, exit_code, artifact, Some(outcome), None)
}

fn emit_json_envelope(
  command: String,
  ok: Bool,
  exit_code: Int,
  artifact: Option(json.Json),
  outcome: Option(json.Json),
  error: Option(json.Json),
) -> Nil {
  json.object([
    #("schema_version", json.int(1)),
    #("command", json.string(command)),
    #("ok", json.bool(ok)),
    #("exit_code", json.int(exit_code)),
    #("artifact", json.nullable(artifact, fn(value) { value })),
    #("outcome", json.nullable(outcome, fn(value) { value })),
    #("error", json.nullable(error, fn(value) { value })),
  ])
  |> json.to_string
  |> io.println
}

fn run_demo(mode: cli.DemoMode, out: String, port: Int) -> Int {
  use command <- result_or_exit(record_process.demo_command())
  let temporary = out == ""
  let output = case temporary {
    True -> temporary_archive_path()
    False -> out
  }
  let recorded =
    run_record(
      None,
      cli.Mfa("beamtrace_demo_fixture", "run", 0),
      None,
      output,
      None,
      1,
      types.Generic,
      command,
      demo_staged_modules,
      cli.default_window_s,
      False,
    )
  let result = case recorded, mode {
    0, cli.DemoWeb -> run_open(output, cli.Web, port)
    0, cli.DemoWebNoOpen -> run_open(output, cli.WebNoOpen, port)
    0, cli.DemoTui -> run_open(output, cli.TuiMode, port)
    0, cli.DemoNoUi -> 0
    code, _ -> code
  }
  case temporary && record_wrote_archive(recorded) {
    True -> delete_file(output)
    False -> Nil
  }
  result
}

fn record_wrote_archive(exit_code: Int) -> Bool {
  exit_code == 0 || exit_code == 1 || exit_code == 3
}

fn run_relay(
  hub_url: String,
  enrollment_token: String,
  target: Option(cli.RelayTarget),
) -> Int {
  let identity = relay_channel.new_identity()
  case relay_client.enroll(hub_url, enrollment_token, identity) {
    Error(error) ->
      fail("relay enrollment failed: " <> relay_client_error_message(error), 2)
    Ok(receipt) -> {
      io.println("Enrolled relay " <> receipt.relay_id)
      io.println("Outbound channel: " <> receipt.channel_url)
      case target {
        None -> {
          io.println("Relay channel connected; press Ctrl+C to stop.")
          case relay_client.run_channel(receipt, identity) {
            Ok(Nil) -> 0
            Error(reason) -> fail("relay channel stopped: " <> reason, 2)
          }
        }
        Some(target) -> run_relay_capture(receipt, identity, target)
      }
    }
  }
}

fn run_relay_capture(
  receipt: relay_client.EnrollmentReceipt,
  identity: relay_channel.Identity,
  target: cli.RelayTarget,
) -> Int {
  use Nil <- error_or_exit(preflight_agent())
  use cookie <- result_or_exit(read_cookie(target.cookie_file))
  use grant <- raw_grant_or_exit(load_raw_grant(receipt, target.raw_grant_file))
  let cli.Mfa(module, function, arity) = target.trigger
  let nodes = target.node |> string.split(on: ",") |> list.map(string.trim)
  io.println(
    "Relay capture armed for "
    <> module
    <> ":"
    <> function
    <> "/"
    <> int.to_string(arity)
    <> "; perform one operation.",
  )
  let default_budget = types.default_budget()
  let #(privacy, budget) = case grant {
    None -> #(
      types.Metadata,
      types.TraceBudget(..default_budget, max_roots: target.max_roots),
    )
    Some(raw) -> {
      let remaining_ms = raw.expires_at_ms - local_auth.now_ms()
      #(
        types.Raw(raw.policy),
        types.TraceBudget(
          ..default_budget,
          max_events: int.min(default_budget.max_events, raw.max_events),
          max_bytes: int.min(default_budget.max_bytes, raw.max_bytes),
          max_duration_ms: int.min(default_budget.max_duration_ms, remaining_ms),
          max_roots: target.max_roots,
        ),
      )
    }
  }
  let spec =
    types.CaptureSpec(
      nodes: nodes,
      trigger: types.Mfa(module, function, arity),
      where_aql: target.where_aql,
      privacy: privacy,
      budget: budget,
      preset: target.preset,
    )
  use captured <- capture_result_or_exit(capture.execute(spec, cookie))
  let transfer =
    relay_client.TransferMetadata(
      node: target.node,
      module: module,
      function: function,
      arity: arity,
      delivery_status: case types.delivery_verified(captured.outcome) {
        True -> relay_session.Delivered
        False -> relay_session.Partial
      },
    )
  let transferred = case grant {
    None ->
      relay_client.run_channel_with_events(
        receipt,
        identity,
        relay_channel.Exact,
        transfer,
        captured.events,
      )
    Some(raw) ->
      relay_client.run_channel_with_raw_events(
        receipt,
        identity,
        relay_channel.Exact,
        transfer,
        raw.grant,
        raw.policy,
        captured.events,
      )
  }
  case transferred {
    Error(reason) -> fail("relay producer incomplete: " <> reason, 3)
    Ok(Nil) -> {
      io.println(
        "Transferred "
        <> int.to_string(list.length(captured.events))
        <> " events after durable hub acknowledgement.",
      )
      capture.exit_code(captured.outcome)
    }
  }
}

fn load_raw_grant(
  receipt: relay_client.EnrollmentReceipt,
  path: Option(String),
) -> Result(Option(raw_grant_file.GrantFile), String) {
  case path {
    None -> Ok(None)
    Some(path) -> {
      io.println(
        "Raw capture requested. Authorize relay "
        <> receipt.relay_id
        <> " and write the one-time grant JSON to "
        <> path
        <> ". Waiting up to 5 minutes.",
      )
      case raw_grant_file.wait_load(path, 300_000) {
        Error(error) -> Error(error)
        Ok(grant) ->
          case
            raw_grant_file.authorize_for_relay(
              grant,
              receipt.relay_id,
              local_auth.now_ms(),
            )
          {
            Ok(Nil) -> Ok(Some(grant))
            Error(error) -> Error(error)
          }
      }
    }
  }
}

fn raw_grant_or_exit(result: Result(a, String), next: fn(a) -> Int) -> Int {
  case result {
    Ok(value) -> next(value)
    Error(error) -> fail("raw capture refused: " <> error, 4)
  }
}

fn run_serve(port: Int, open_browser: Bool) -> Int {
  case team_config.load_environment() {
    Ok(None) -> run_server_with_browser(api.Local, None, port, open_browser)
    Ok(Some(config)) ->
      case
        server.start_team(
          config: config,
          secret_key_base: random_secret(),
          static_root: Some(web_root()),
          archive_path: None,
        )
      {
        Ok(Nil) -> 0
        Error(error) -> fail("team server failed: " <> error, 2)
      }
    Error(error) ->
      fail(
        "invalid team configuration: " <> team_config_error_message(error),
        2,
      )
  }
}

fn run_capture(
  node: String,
  trigger: cli.Mfa,
  where_aql: Option(String),
  out: String,
  cookie_file: Option(String),
  max_roots: Int,
  preset: types.Preset,
  window_s: Int,
  force: Bool,
) -> Int {
  let output = case out == "" {
    True -> default_archive_path()
    False -> out
  }
  use Nil <- output_or_exit(output, force)
  use Nil <- error_or_exit(preflight_agent())
  use cookie <- result_or_exit(read_cookie(cookie_file))
  let cli.Mfa(module, function, arity) = trigger
  let core_trigger = types.Mfa(module, function, arity)
  let nodes = string.split(node, on: ",") |> list.map(string.trim)
  use result <- capture_result_or_exit(capture.execute(
    types.CaptureSpec(
      nodes: nodes,
      trigger: core_trigger,
      where_aql: where_aql,
      privacy: types.Metadata,
      budget: types.TraceBudget(
        ..types.default_budget(),
        max_roots: max_roots,
        max_duration_ms: window_s * 1000,
      ),
      preset: preset,
    ),
    cookie,
  ))
  let manifest =
    codec.Manifest(
      schema_version: codec.schema_version,
      tool_version: version,
      capture_id: capture_id(),
      nodes: nodes,
      outcome: result.outcome,
      privacy: types.Metadata,
    )
  let saved = case force {
    True ->
      storage.save_with_clocks(output, manifest, result.events, result.clocks)
    False ->
      storage.save_exclusive_with_clocks(
        output,
        manifest,
        result.events,
        result.clocks,
      )
  }
  case saved {
    Ok(Nil) -> {
      io.println(
        "Saved "
        <> int.to_string(list.length(result.events))
        <> " events to "
        <> output,
      )
      capture.exit_code(result.outcome)
    }
    Error(error) -> fail_with(cli_errors.from_storage(error, output))
  }
}

/// Migration reads `path` and writes `output`; attribute the failure to the
/// file it concerns.
fn migrate_error(
  error: storage.StorageError,
  path: String,
  output: String,
) -> cli_errors.CliError {
  case error {
    storage.MigrationRequiresDistinctOutput
    | storage.IoError("destination_exists") ->
      cli_errors.from_storage(error, output)
    _ -> cli_errors.from_storage(error, path)
  }
}

fn run_attach(
  node: String,
  mode: cli.UiMode,
  cookie_file: Option(String),
  port: Int,
) -> Int {
  use Nil <- error_or_exit(preflight_agent())
  use cookie <- result_or_exit(read_cookie(cookie_file))
  case capture.probe(node, cookie) {
    Error(error) -> fail("attach failed: " <> error, 2)
    Ok(otp) -> {
      let capture_store = capture_session.new([node], cookie)
      case mode {
        cli.TuiMode -> {
          io.println("Attached " <> node <> " (OTP " <> otp <> ").")
          beamtrace_tui.run_attached_with_driver(
            [],
            node,
            tui_driver.new(capture_store, version),
          )
          capture_session.close(capture_store)
          0
        }
        cli.Web | cli.WebNoOpen -> {
          io.println("Attached " <> node <> " (OTP " <> otp <> ").")
          case
            server.start_attached_with_browser(
              bind: "127.0.0.1",
              port: port,
              mode: api.Local,
              secret_key_base: random_secret(),
              static_root: Some(web_root()),
              capture_store: capture_store,
              open_browser: mode == cli.Web && terminal_interactive(),
            )
          {
            Ok(Nil) -> 0
            Error(error) -> fail("server failed: " <> error, 2)
          }
        }
      }
    }
  }
}

fn run_open(path: String, mode: cli.UiMode, port: Int) -> Int {
  case mode {
    cli.Web | cli.WebNoOpen ->
      case storage.window(path, start: 0, limit: 1) {
        Error(error) -> fail_with(cli_errors.from_storage(error, path))
        Ok(window) -> {
          io.println(path <> ": " <> int.to_string(window.total) <> " events")
          run_server_with_browser(
            api.Local,
            Some(path),
            port,
            mode == cli.Web && terminal_interactive(),
          )
        }
      }
    cli.TuiMode ->
      case storage.load(path) {
        Error(error) -> fail_with(cli_errors.from_storage(error, path))
        Ok(archive) -> {
          beamtrace_tui.run_archive(archive.events, archive.manifest.nodes)
          0
        }
      }
  }
}

fn run_compare(left: String, right: String) -> Int {
  case storage.load(left), storage.load(right) {
    Ok(left_archive), Ok(right_archive) ->
      case diff.compare(left_archive.events, right_archive.events) {
        Error(error) ->
          fail_with(cli_errors.invalid_trace_graph(dag.error_message(error)))
        Ok(report) -> {
          let statistics =
            stats.from_traces([left_archive.events, right_archive.events])
          io.println(command.compare_summary(report, statistics))
          command.compare_exit(report)
        }
      }
    Error(error), _ -> fail_with(cli_errors.from_storage(error, left))
    _, Error(error) -> fail_with(cli_errors.from_storage(error, right))
  }
}

fn run_export(path: String, format: cli.ExportFormat, anchor_now: Bool) -> Int {
  case storage.load(path) {
    Error(error) -> fail_with(cli_errors.from_storage(error, path))
    Ok(archive) -> {
      let output = command.export_path(path, format)
      let content = case format {
        cli.Html -> Ok(export.html(archive, include_raw: False))
        cli.Jsonl -> Ok(export.jsonl(archive, include_raw: False))
        cli.Mermaid -> Ok(export.mermaid(archive))
        cli.Otlp ->
          export.otlp(archive, include_raw: False, anchor_now: anchor_now)
      }
      case content {
        Error(error) -> fail("could not export OTLP: " <> error, 2)
        Ok(content) ->
          case write_text(output, content) {
            Ok(Nil) -> {
              io.println("Exported " <> output)
              0
            }
            Error(error) -> fail("could not write export: " <> error, 2)
          }
      }
    }
  }
}

fn run_validate(path: String, as_json: Bool) -> Int {
  case storage.validate(path) {
    Ok(archive) -> {
      case as_json {
        True ->
          emit_json_outcome_result(
            "validate",
            0,
            Some(
              json.object([
                #("path", json.string(path)),
                #("schema_version", json.int(archive.manifest.schema_version)),
                #("event_count", json.int(list.length(archive.events))),
              ]),
            ),
            codec.outcome_json(archive.manifest.outcome),
          )
        False ->
          io.println(
            "Valid .beamtrace schema v"
            <> int.to_string(archive.manifest.schema_version)
            <> " · "
            <> int.to_string(list.length(archive.events))
            <> " events · checksums and causal graph verified",
          )
      }
      0
    }
    Error(error) -> {
      let failure = cli_errors.from_storage(error, path)
      case as_json {
        True -> emit_json_failure("validate", failure)
        False -> {
          let _ = fail_with(failure)
          Nil
        }
      }
      cli_errors.exit_code(failure)
    }
  }
}

fn run_migrate(path: String, output: String) -> Int {
  case storage.migrate(path, output, version) {
    Ok(Nil) -> {
      io.println("Migrated " <> path <> " to schema v2 at " <> output)
      0
    }
    Error(error) -> fail_with(migrate_error(error, path, output))
  }
}

fn run_record(
  requested_node: Option(String),
  trigger: cli.Mfa,
  where_aql: Option(String),
  out: String,
  cookie_file: Option(String),
  max_roots: Int,
  preset: types.Preset,
  child: List(String),
  staged_modules: List(String),
  window_s: Int,
  force: Bool,
) -> Int {
  let output = case out == "" {
    True -> default_archive_path()
    False -> out
  }
  use Nil <- output_or_exit(output, force)
  use Nil <- error_or_exit(preflight_agent())
  io.println("Connecting to the record target…")
  use cookie <- result_or_exit(read_record_cookie(cookie_file))
  use node <- result_or_exit(case requested_node {
    Some(node) -> Ok(node)
    None -> record_process.auto_node()
  })
  let nodes = string.split(node, on: ",") |> list.map(string.trim)
  case nodes {
    [] -> fail("record requires at least one target node", 2)
    [root, ..] -> {
      let cli.Mfa(trigger_module, _, _) = trigger
      case
        record_process.start_staged(
          child,
          root,
          cookie,
          trigger_module,
          staged_modules,
        )
      {
        Error(error) -> fail_with(child_start_error(error))
        Ok(handle) ->
          case capture.wait_until_available(root, cookie, 10_000) {
            Error(error) -> record_start_failure(handle, error)
            Ok(Nil) -> {
              io.println("Connected. Arming the selected MFA…")
              let store = capture_session.new(nodes, cookie)
              let result =
                run_record_session(
                  store,
                  handle,
                  nodes,
                  cookie,
                  trigger,
                  where_aql,
                  output,
                  max_roots,
                  preset,
                  window_s,
                  force,
                )
              capture_session.close(store)
              record_exit_code(result)
            }
          }
      }
    }
  }
}

fn record_start_failure(handle: record_process.Handle, reason: String) -> Int {
  case record_process.shutdown_exit_code() {
    code if code != 0 -> {
      record_process.stop(handle)
      code
    }
    _ -> record_start_failure_without_signal(handle, reason)
  }
}

fn record_start_failure_without_signal(
  handle: record_process.Handle,
  reason: String,
) -> Int {
  fail_with(record_start_error(handle, reason))
}

/// Classify a child that never exposed its node: a VM that already exited
/// crashed during boot (its bounded output tail is the detail); a hung VM is
/// closed and reported as unreachable.
fn record_start_error(
  handle: record_process.Handle,
  reason: String,
) -> cli_errors.CliError {
  let wait = case record_process.is_running(handle) {
    False -> 1000
    True -> 1
  }
  case record_process.await(handle, wait) {
    Ok(#(status, output)) if status != 0 ->
      cli_errors.child_crashed(status) |> cli_errors.with_detail(output)
    Ok(#(_, output)) ->
      cli_errors.from_capture_reason(reason) |> cli_errors.with_detail(output)
    Error(error) ->
      cli_errors.from_capture_reason(reason) |> cli_errors.with_detail(error)
  }
}

fn child_start_error(reason: String) -> cli_errors.CliError {
  case string.starts_with(reason, "executable_not_found: ") {
    True -> cli_errors.from_capture_reason(reason)
    False -> cli_errors.child_start_failed(reason)
  }
}

/// Prefer the reason the capture session recorded over the target-side
/// polling result, which can only say that arming never became visible.
fn arm_failure(
  store: capture_session.Store,
  error: String,
) -> cli_errors.CliError {
  case capture_session.status(store) {
    capture_session.Failed(reason) -> cli_errors.from_capture_reason(reason)
    _ -> cli_errors.from_capture_reason(error)
  }
}

fn preflight_agent() -> Result(Nil, cli_errors.CliError) {
  case capture.agent_available() {
    Ok(_) -> Ok(Nil)
    Error(reason) ->
      Error(
        cli_errors.agent_beam_unavailable(capture.bundled_runtime())
        |> cli_errors.with_detail(case reason {
          "agent_beam_unavailable" -> ""
          other -> other
        }),
      )
  }
}

fn preflight_web_assets() -> Result(Nil, cli_errors.CliError) {
  case capture.web_assets_available() {
    Ok(_) -> Ok(Nil)
    Error(_) ->
      Error(cli_errors.web_assets_unavailable(capture.bundled_runtime()))
  }
}

fn json_error_or_exit(
  command: String,
  result: Result(a, cli_errors.CliError),
  next: fn(a) -> Int,
) -> Int {
  case result {
    Ok(value) -> next(value)
    Error(error) -> {
      emit_json_failure(command, error)
      cli_errors.exit_code(error)
    }
  }
}

fn error_or_exit(
  result: Result(a, cli_errors.CliError),
  next: fn(a) -> Int,
) -> Int {
  case result {
    Ok(value) -> next(value)
    Error(error) -> fail_with(error)
  }
}

fn machine_result_error(
  result: Result(a, cli_errors.CliError),
  next: fn(a) -> Result(b, cli_errors.CliError),
) -> Result(b, cli_errors.CliError) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn run_record_session(
  store: capture_session.Store,
  handle: record_process.Handle,
  nodes: List(String),
  cookie: String,
  trigger: cli.Mfa,
  where_aql: Option(String),
  out: String,
  max_roots: Int,
  preset: types.Preset,
  window_s: Int,
  force: Bool,
) -> Int {
  let cli.Mfa(module, function, arity) = trigger
  let core_trigger = types.Mfa(module, function, arity)
  let spec =
    capture_session.ArmSpec(
      trigger: core_trigger,
      where_aql: where_aql,
      capture_window_ms: window_s * 1000,
      drain_timeout_ms: 10_000,
      budget: capture.default_budget(),
      max_roots: max_roots,
      preset: preset,
    )
  case capture_session.arm(store, spec), nodes {
    Error(error), _ -> {
      record_process.stop(handle)
      fail("record could not arm capture: " <> session_error_message(error), 2)
    }
    _, [] -> {
      record_process.stop(handle)
      fail("record requires at least one target node", 2)
    }
    Ok(Nil), [root, ..] ->
      case capture.wait_until_armed(root, cookie, 5000) {
        Error(error) -> {
          let failure = arm_failure(store, error)
          let _ = capture_session.cancel(store)
          record_process.stop(handle)
          fail_with(failure)
        }
        Ok(Nil) -> {
          io.println("Capture armed. Starting the application command…")
          case record_process.release(handle) {
            Error(error) -> {
              let _ = capture_session.cancel(store)
              record_process.stop(handle)
              fail("record could not release child: " <> error, 2)
            }
            Ok(Nil) ->
              run_record_child(store, handle, nodes, out, window_s, force)
          }
        }
      }
  }
}

fn run_record_child(
  store: capture_session.Store,
  handle: record_process.Handle,
  nodes: List(String),
  out: String,
  window_s: Int,
  force: Bool,
) -> Int {
  io.println("Waiting for the operation; capture remains armed…")
  let captured = await_record_with_progress(store, window_s * 1000 + 5000, 5000)
  case record_process.shutdown_exit_code() {
    code if code != 0 -> {
      let _ = capture_session.cancel(store)
      record_process.stop(handle)
      code
    }
    _ ->
      case captured {
        Error(error) -> record_capture_failure(store, handle, error)
        Ok(result) -> {
          io.println("Observation ended. Sealing and verifying delivery…")
          finish_record_child(handle, nodes, out, result, force)
        }
      }
  }
}

fn await_record_with_progress(
  store: capture_session.Store,
  remaining_ms: Int,
  heartbeat_ms: Int,
) -> Result(capture.CaptureResult, capture_session.SessionError) {
  case capture_session.result(store) {
    Ok(result) -> Ok(result)
    Error(capture_session.CaptureNotReady) if remaining_ms > 0 -> {
      let heartbeat_ms = case heartbeat_ms <= 0 {
        True -> {
          io.println("Still waiting; the capture is armed and bounded…")
          5000
        }
        False -> heartbeat_ms
      }
      let step_ms = int.min(250, remaining_ms)
      process.sleep(step_ms)
      await_record_with_progress(
        store,
        remaining_ms - step_ms,
        heartbeat_ms - step_ms,
      )
    }
    Error(capture_session.CaptureNotReady) ->
      Error(capture_session.CaptureTimeout)
    Error(error) -> Error(error)
  }
}

fn record_exit_code(result: Int) -> Int {
  case record_process.shutdown_exit_code() {
    0 -> result
    signal_status -> signal_status
  }
}

fn record_capture_failure(
  store: capture_session.Store,
  handle: record_process.Handle,
  error: capture_session.SessionError,
) -> Int {
  let _ = capture_session.cancel(store)
  let finish = record_process.release_finish(handle)
  let child = record_process.await(handle, 1000)
  let child_diagnostic = case finish, child {
    Error(reason), _ -> {
      record_process.stop(handle)
      "child shutdown gate failed: " <> reason
    }
    Ok(Nil), Ok(#(status, output)) ->
      "child exited with status " <> int.to_string(status) <> "\n" <> output
    Ok(Nil), Error(reason) -> reason
  }
  let failure = case error {
    capture_session.CaptureFailed(reason) ->
      cli_errors.from_capture_reason(reason)
    capture_session.CaptureTimeout -> cli_errors.capture_incomplete()
    other -> cli_errors.command_failed(session_error_message(other))
  }
  fail_with(cli_errors.with_detail(failure, child_diagnostic))
}

fn finish_record_child(
  handle: record_process.Handle,
  nodes: List(String),
  out: String,
  result: capture.CaptureResult,
  force: Bool,
) -> Int {
  case record_process.release_finish(handle) {
    Error(error) -> {
      record_process.stop(handle)
      fail("record could not release child shutdown: " <> error, 2)
    }
    Ok(Nil) ->
      case record_process.await(handle, 86_400_000) {
        Error(error) -> fail("record child failed: " <> error, 2)
        Ok(#(child_status, output)) -> {
          io.print(output)
          case save_result(out, nodes, result, types.Metadata, force) {
            Error(error) -> fail_with(error)
            Ok(Nil) ->
              case storage.validate(out) {
                Error(error) -> fail_with(cli_errors.from_storage(error, out))
                Ok(_) -> {
                  io.println(
                    "Archive sealed; checksums and causal graph verified.",
                  )
                  io.println(
                    "Saved "
                    <> int.to_string(list.length(result.events))
                    <> " events to "
                    <> out,
                  )
                  case child_status {
                    0 -> capture.exit_code(result.outcome)
                    _ -> 1
                  }
                }
              }
          }
        }
      }
  }
}

fn read_record_cookie(cookie_file: Option(String)) -> Result(String, String) {
  let result = case cookie_file {
    Some(path) -> read_cookie_file(path)
    None -> record_process.ephemeral_cookie()
  }
  case result {
    Ok(cookie) -> Ok(cookie)
    Error(_) ->
      Error(
        "distribution cookie unavailable; use a private --cookie-file or an ephemeral record cookie",
      )
  }
}

fn save_result(
  out: String,
  nodes: List(String),
  result: capture.CaptureResult,
  privacy: types.Privacy,
  force: Bool,
) -> Result(Nil, cli_errors.CliError) {
  let manifest =
    codec.Manifest(
      schema_version: codec.schema_version,
      tool_version: version,
      capture_id: capture_id(),
      nodes: nodes,
      outcome: result.outcome,
      privacy: privacy,
    )
  let saved = case force {
    True ->
      storage.save_with_clocks(out, manifest, result.events, result.clocks)
    False ->
      storage.save_exclusive_with_clocks(
        out,
        manifest,
        result.events,
        result.clocks,
      )
  }
  case saved {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error(cli_errors.from_storage(error, out))
  }
}

fn run_server_with_browser(
  mode: api.ServerMode,
  archive_path: Option(String),
  port: Int,
  open_browser: Bool,
) -> Int {
  use Nil <- error_or_exit(preflight_web_assets())
  case
    server.start_with_browser(
      bind: "127.0.0.1",
      port: port,
      mode: mode,
      secret_key_base: random_secret(),
      static_root: Some(web_root()),
      archive_path: archive_path,
      open_browser: open_browser,
    )
  {
    Ok(Nil) -> 0
    Error(error) -> fail("server failed: " <> error, 2)
  }
}

fn read_cookie(cookie_file: Option(String)) -> Result(String, String) {
  let result = case cookie_file {
    Some(path) -> read_cookie_file(path)
    None -> read_cookie_default()
  }
  case result {
    Ok(cookie) -> Ok(cookie)
    Error(_) ->
      Error(
        "distribution cookie unavailable; use --cookie-file, BEAMTRACE_COOKIE, or the secure prompt",
      )
  }
}

fn result_or_exit(result: Result(a, String), next: fn(a) -> Int) -> Int {
  case result {
    Ok(value) -> next(value)
    Error(error) -> fail(error, 2)
  }
}

fn capture_result_or_exit(
  result: Result(a, String),
  next: fn(a) -> Int,
) -> Int {
  case result {
    Ok(value) -> next(value)
    Error(error) -> fail_with(cli_errors.from_capture_reason(error))
  }
}

fn fail(message: String, code: Int) -> Int {
  fail_with(cli_errors.legacy(message, code))
}

fn fail_with(error: cli_errors.CliError) -> Int {
  list.each(cli_errors.render_human(error), io.println_error)
  cli_errors.exit_code(error)
}

fn relay_client_error_message(error: relay_client.RelayClientError) -> String {
  case error {
    relay_client.InsecureHubUrl -> "the hub URL must use HTTPS"
    relay_client.InvalidHubUrl -> "the hub URL is invalid"
    relay_client.InvalidEnrollmentToken -> "the enrollment token is invalid"
    relay_client.TransportError(_) -> "the verified hub transport failed"
    relay_client.InvalidResponse(_) -> "the hub returned an invalid response"
  }
}

fn team_config_error_message(error: team_config.ConfigError) -> String {
  case error {
    team_config.Missing(key) -> "missing required setting '" <> key <> "'"
    team_config.DistributionCookieForbidden ->
      "distribution cookies are forbidden in Team configuration"
    team_config.ClientSecretForbidden ->
      "OIDC client secrets are forbidden in Team configuration"
    team_config.BlobSecretForbidden ->
      "S3 credentials must come from the platform credential chain"
    team_config.InvalidUrl(key) ->
      "setting '" <> key <> "' must be a safe HTTPS URL"
    team_config.RedirectOriginMismatch ->
      "the OIDC redirect URI must use the configured Team origin"
    team_config.InvalidRoleMapping(_) -> "the OIDC role mapping is invalid"
    team_config.InvalidInteger(key, _) ->
      "setting '" <> key <> "' is out of range"
    team_config.InvalidValue(key) -> "setting '" <> key <> "' is invalid"
    team_config.JwksReadFailed(path, _) ->
      "the public JWKS file could not be read at '" <> path <> "'"
    team_config.InvalidJwks ->
      "the JWKS must contain only supported public signing keys"
    team_config.DiscoveryFailed(reason) ->
      "OIDC discovery failed: " <> discovery_error_message(reason)
  }
}

fn discovery_error_message(error: oidc_discovery.DiscoveryError) -> String {
  case error {
    oidc_discovery.InvalidIssuer -> "the issuer must be an HTTPS URL"
    oidc_discovery.TransportFailed -> "the HTTPS provider request failed"
    oidc_discovery.UnexpectedStatus(status) ->
      "the provider returned HTTP " <> int.to_string(status)
    oidc_discovery.ResponseTooLarge ->
      "the provider response exceeded its limit"
    oidc_discovery.MalformedMetadata -> "the provider metadata is malformed"
    oidc_discovery.IssuerMismatch ->
      "the returned issuer does not exactly match configuration"
    oidc_discovery.InvalidEndpoint(field) ->
      "provider field '" <> field <> "' is not a safe HTTPS URL"
    oidc_discovery.InvalidJwks ->
      "the provider JWKS contains an unsupported or private key"
  }
}

fn session_error_message(error: capture_session.SessionError) -> String {
  case error {
    capture_session.CaptureAlreadyRunning -> "another capture is already active"
    capture_session.CaptureNotReady -> "the capture is not ready"
    capture_session.CaptureTimeout -> "the capture timed out"
    capture_session.SessionClosed -> "the capture session is closed"
    capture_session.InvalidSessionRequest(_) -> "the capture request is invalid"
    capture_session.CaptureFailed(reason) -> capture.failure_guidance(reason)
  }
}

@external(erlang, "beamtrace_cli_ffi", "read_cookie_file")
fn read_cookie_file(path: String) -> Result(String, String)

@external(erlang, "beamtrace_cli_ffi", "absolute_path")
fn absolute_path(path: String) -> String

fn error_catalogue_help() -> String {
  let rows =
    cli_errors.all()
    |> list.map(fn(error) {
      "  "
      <> string.pad_end(cli_errors.human_label(error), 30, " ")
      <> "exit "
      <> int.to_string(cli_errors.exit_code(error))
      <> "  "
      <> error.message
    })
    |> string.join("\n")
  let exits =
    cli_errors.all_exit_codes()
    |> list.map(fn(exit) {
      "  "
      <> string.pad_end(int.to_string(cli_errors.exit_to_int(exit)), 5, " ")
      <> cli_errors.exit_description(exit)
    })
    |> string.join("\n")
  "Error codes (the JSON error.code is the lower-case label):\n"
  <> rows
  <> "\n\nExit codes:\n"
  <> exits
}

fn path_artifact(path: String) -> List(#(String, json.Json)) {
  [
    #("path", json.string(path)),
    #("absolute_path", json.string(absolute_path(path))),
  ]
}

@external(erlang, "beamtrace_cli_ffi", "read_cookie_default")
fn read_cookie_default() -> Result(String, String)

@external(erlang, "beamtrace_cli_ffi", "write_text")
fn write_text(path: String, content: String) -> Result(Nil, String)

@external(erlang, "beamtrace_cli_ffi", "random_secret")
fn random_secret() -> String

@external(erlang, "beamtrace_cli_ffi", "capture_id")
fn capture_id() -> String

@external(erlang, "beamtrace_cli_ffi", "default_archive_path")
fn default_archive_path() -> String

@external(erlang, "beamtrace_cli_ffi", "temporary_archive_path")
fn temporary_archive_path() -> String

@external(erlang, "beamtrace_cli_ffi", "path_exists")
fn path_exists(path: String) -> Bool

@external(erlang, "beamtrace_cli_ffi", "delete_file")
fn delete_file(path: String) -> Nil

@external(erlang, "beamtrace_cli_ffi", "web_root")
fn web_root() -> String

@external(erlang, "beamtrace_cli_ffi", "doctor")
fn doctor(
  json: Bool,
  profile_status: String,
  configured_cookie_files: List(String),
) -> String

@external(erlang, "beamtrace_cli_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "beamtrace_cli_ffi", "terminal_interactive")
fn terminal_interactive() -> Bool

@external(erlang, "beamtrace_cli_ffi", "confirm_seq_trace")
fn confirm_seq_trace() -> Bool
