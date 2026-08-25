// SPDX-License-Identifier: Apache-2.0 OR MIT
import argv
import beamtrace/codec
import beamtrace/diff
import beamtrace/stats
import beamtrace/types
import beamtrace_runtime/api
import beamtrace_runtime/capture
import beamtrace_runtime/capture_session
import beamtrace_runtime/cli
import beamtrace_runtime/command
import beamtrace_runtime/export
import beamtrace_runtime/internal/version as runtime_version
import beamtrace_runtime/local_auth
import beamtrace_runtime/mcp
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
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const version = runtime_version.current

pub fn main() {
  let arguments = argv.load().arguments
  let parsed = case project_config.prepare(arguments) {
    Ok(arguments) -> cli.parse(arguments)
    Error(message) -> Error(cli.ParseError(message, 2))
  }
  let code = case parsed {
    Ok(command) -> run(command)
    Error(cli.ParseError(message, exit_code)) -> {
      io.println_error("beamtrace: " <> message)
      io.println_error("Run 'beamtrace help' for usage.")
      exit_code
    }
  }
  halt(code)
}

fn run(command_: cli.Command) -> Int {
  case command_ {
    cli.Help -> {
      io.println(help_text())
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
    cli.Capture(node, trigger, where_aql, out, cookie_file, max_roots, preset) ->
      run_capture(node, trigger, where_aql, out, cookie_file, max_roots, preset)
    cli.Attach(node, mode, cookie_file, port) ->
      run_attach(node, mode, cookie_file, port)
    cli.Open(path, mode, port) -> run_open(path, mode, port)
    cli.Compare(left, right) -> run_compare(left, right)
    cli.Export(path, format) -> run_export(path, format)
    cli.Record(
      node,
      trigger,
      where_aql,
      out,
      cookie_file,
      max_roots,
      preset,
      child,
    ) ->
      run_record(
        node,
        trigger,
        where_aql,
        out,
        cookie_file,
        max_roots,
        preset,
        child,
      )
    cli.Serve(port) -> run_serve(port)
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

fn run_demo(mode: cli.DemoMode, out: String, port: Int) -> Int {
  use command <- result_or_exit(record_process.demo_command())
  let recorded =
    run_record(
      None,
      cli.Mfa("beamtrace_demo_fixture", "run", 0),
      None,
      out,
      None,
      1,
      types.Generic,
      command,
    )
  case recorded, mode {
    0, cli.DemoWeb -> run_open(out, cli.Web, port)
    0, cli.DemoTui -> run_open(out, cli.TuiMode, port)
    0, cli.DemoNoUi -> 0
    code, _ -> code
  }
}

fn run_relay(
  hub_url: String,
  enrollment_token: String,
  target: Option(cli.RelayTarget),
) -> Int {
  let identity = relay_channel.new_identity()
  case relay_client.enroll(hub_url, enrollment_token, identity) {
    Error(error) ->
      fail("relay enrollment failed: " <> string.inspect(error), 2)
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
  use cookie <- result_or_exit(read_cookie(target.cookie_file))
  use grant <- raw_grant_or_exit(load_raw_grant(receipt, target.raw_grant_file))
  let cli.Mfa(module_, function_, arity) = target.trigger
  let nodes = target.node |> string.split(on: ",") |> list.map(string.trim)
  io.println(
    "Relay capture armed for "
    <> module_
    <> ":"
    <> function_
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
      trigger: types.Mfa(module_, function_, arity),
      where_aql: target.where_aql,
      privacy: privacy,
      budget: budget,
      preset: target.preset,
    )
  use captured <- capture_result_or_exit(capture.execute(spec, cookie))
  let transfer =
    relay_client.TransferMetadata(
      node: target.node,
      module_: module_,
      function_: function_,
      arity: arity,
      completeness: case captured.completeness {
        types.Complete -> relay_session.Complete
        _ -> relay_session.Truncated
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
      case captured.completeness {
        types.Complete -> 0
        _ -> 3
      }
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

fn run_serve(port: Int) -> Int {
  case team_config.load_environment() {
    Ok(None) -> run_server(api.Local, None, port)
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
      fail("invalid team configuration: " <> string.inspect(error), 2)
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
) -> Int {
  use cookie <- result_or_exit(read_cookie(cookie_file))
  let cli.Mfa(module_, function_, arity) = trigger
  let core_trigger = types.Mfa(module_, function_, arity)
  let nodes = string.split(node, on: ",") |> list.map(string.trim)
  use result <- capture_result_or_exit(capture.execute(
    types.CaptureSpec(
      nodes: nodes,
      trigger: core_trigger,
      where_aql: where_aql,
      privacy: types.Metadata,
      budget: types.TraceBudget(..types.default_budget(), max_roots: max_roots),
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
      completeness: result.completeness,
      privacy: types.Metadata,
      checksums: [],
    )
  case storage.save(out, manifest, result.events) {
    Ok(Nil) -> {
      io.println(
        "Saved "
        <> int.to_string(list.length(result.events))
        <> " events to "
        <> out,
      )
      capture.exit_code(result.completeness)
    }
    Error(error) -> fail("could not save capture: " <> string.inspect(error), 2)
  }
}

fn run_attach(
  node: String,
  mode: cli.UiMode,
  cookie_file: Option(String),
  port: Int,
) -> Int {
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
        cli.Web -> {
          io.println("Attached " <> node <> " (OTP " <> otp <> ").")
          case
            server.start_attached(
              bind: "127.0.0.1",
              port: port,
              mode: api.Local,
              secret_key_base: random_secret(),
              static_root: Some(web_root()),
              capture_store: capture_store,
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
    cli.Web ->
      case storage.window(path, start: 0, limit: 1) {
        Error(error) ->
          fail("could not open trace: " <> string.inspect(error), 2)
        Ok(window) -> {
          io.println(path <> ": " <> int.to_string(window.total) <> " events")
          run_server(api.Local, Some(path), port)
        }
      }
    cli.TuiMode ->
      case storage.load(path) {
        Error(error) ->
          fail("could not open trace: " <> string.inspect(error), 2)
        Ok(archive) -> {
          beamtrace_tui.run_archive(archive.events, archive.manifest.nodes)
          0
        }
      }
  }
}

fn run_compare(left: String, right: String) -> Int {
  case storage.load(left), storage.load(right) {
    Ok(left_archive), Ok(right_archive) -> {
      let report = diff.compare(left_archive.events, right_archive.events)
      let statistics =
        stats.from_traces([left_archive.events, right_archive.events])
      io.println(command.compare_summary(report, statistics))
      command.compare_exit(report)
    }
    Error(error), _ | _, Error(error) ->
      fail("could not compare trace: " <> string.inspect(error), 2)
  }
}

fn run_export(path: String, format: cli.ExportFormat) -> Int {
  case storage.load(path) {
    Error(error) ->
      fail("could not load export source: " <> string.inspect(error), 2)
    Ok(archive) -> {
      let output = command.export_path(path, format)
      let content = case format {
        cli.Html -> export.html(archive, include_raw: False)
        cli.Jsonl -> export.jsonl(archive, include_raw: False)
        cli.Mermaid -> export.mermaid(archive)
        cli.Otlp -> export.otlp(archive, include_raw: False)
      }
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

fn run_record(
  requested_node: Option(String),
  trigger: cli.Mfa,
  where_aql: Option(String),
  out: String,
  cookie_file: Option(String),
  max_roots: Int,
  preset: types.Preset,
  child: List(String),
) -> Int {
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
      case record_process.start(child, root, cookie, trigger_module) {
        Error(error) -> fail("record child failed to start: " <> error, 2)
        Ok(handle) ->
          case capture.wait_until_available(root, cookie, 10_000) {
            Error(error) -> {
              record_start_failure(handle, error)
            }
            Ok(Nil) -> {
              let store = capture_session.new(nodes, cookie)
              let result =
                run_record_session(
                  store,
                  handle,
                  nodes,
                  cookie,
                  trigger,
                  where_aql,
                  out,
                  max_roots,
                  preset,
                )
              capture_session.close(store)
              result
            }
          }
      }
    }
  }
}

fn record_start_failure(handle: record_process.Handle, reason: String) -> Int {
  case record_process.is_running(handle) {
    False ->
      case record_process.await(handle, 1000) {
        Ok(#(status, output)) ->
          fail(
            "record target did not start; child exited with status "
              <> int.to_string(status)
              <> output_tail_message(output)
              <> ": "
              <> reason,
            2,
          )
        Error(error) ->
          fail("record target did not start: " <> reason <> "; " <> error, 2)
      }
    True ->
      // Awaiting for a minimal interval closes a hung child and retains its
      // bounded combined stdout/stderr tail in the timeout diagnostic.
      case record_process.await(handle, 1) {
        Ok(#(status, output)) ->
          fail(
            "record target did not start; child exited with status "
              <> int.to_string(status)
              <> output_tail_message(output)
              <> ": "
              <> reason,
            2,
          )
        Error(error) ->
          fail("record target did not start: " <> reason <> "; " <> error, 2)
      }
  }
}

fn output_tail_message(output: String) -> String {
  case output == "" {
    True -> ""
    False -> "; output tail:\n" <> output
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
) -> Int {
  let cli.Mfa(module_, function_, arity) = trigger
  let core_trigger = types.Mfa(module_, function_, arity)
  let spec =
    capture_session.ArmSpec(
      trigger: core_trigger,
      where_aql: where_aql,
      capture_window_ms: 30_000,
      budget: capture.default_budget(),
      max_roots: max_roots,
      preset: preset,
    )
  case capture_session.arm(store, spec), nodes {
    Error(error), _ -> {
      record_process.stop(handle)
      fail("record could not arm capture: " <> string.inspect(error), 2)
    }
    _, [] -> {
      record_process.stop(handle)
      fail("record requires at least one target node", 2)
    }
    Ok(Nil), [root, ..] ->
      case capture.wait_until_armed(root, cookie, 5000) {
        Error(error) -> {
          let status = capture_session.status(store)
          let _ = capture_session.cancel(store)
          record_process.stop(handle)
          fail(
            "record could not reach the armed state: "
              <> capture.failure_guidance(error)
              <> " (capture "
              <> string.inspect(status)
              <> ")",
            capture.failure_exit_code(error),
          )
        }
        Ok(Nil) ->
          case record_process.release(handle) {
            Error(error) -> {
              let _ = capture_session.cancel(store)
              record_process.stop(handle)
              fail("record could not release child: " <> error, 2)
            }
            Ok(Nil) -> run_record_child(store, handle, nodes, out)
          }
      }
  }
}

fn run_record_child(
  store: capture_session.Store,
  handle: record_process.Handle,
  nodes: List(String),
  out: String,
) -> Int {
  let captured = capture_session.await(store, 35_000)
  case captured {
    Error(error) -> record_capture_failure(store, handle, error)
    Ok(result) -> finish_record_child(handle, nodes, out, result)
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
      "; child shutdown gate failed: " <> reason
    }
    Ok(Nil), Ok(#(status, output)) ->
      "; child exited with status "
      <> int.to_string(status)
      <> output_tail_message(output)
    Ok(Nil), Error(reason) -> "; " <> reason
  }
  let #(message, exit_code) = case error {
    capture_session.CaptureFailed(reason) -> #(
      capture.failure_guidance(reason),
      capture.failure_exit_code(reason),
    )
    capture_session.CaptureTimeout -> #("capture timed out", 2)
    capture_session.CaptureNotReady -> #("capture was not ready", 2)
    capture_session.SessionClosed -> #("capture session closed", 2)
    capture_session.CaptureAlreadyRunning -> #("capture already running", 2)
    capture_session.InvalidSessionRequest(reason) -> #(reason, 2)
  }
  fail("record capture failed: " <> message <> child_diagnostic, exit_code)
}

fn finish_record_child(
  handle: record_process.Handle,
  nodes: List(String),
  out: String,
  result: capture.CaptureResult,
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
          case save_result(out, nodes, result, types.Metadata) {
            Error(error) -> fail("could not save record: " <> error, 2)
            Ok(Nil) -> {
              io.println(
                "Saved "
                <> int.to_string(list.length(result.events))
                <> " events to "
                <> out,
              )
              case child_status {
                0 -> capture.exit_code(result.completeness)
                _ -> 1
              }
            }
          }
        }
      }
  }
}

fn read_record_cookie(cookie_file: Option(String)) -> Result(String, String) {
  case cookie_file {
    Some(path) -> read_cookie_file(path)
    None -> record_process.ephemeral_cookie()
  }
}

fn save_result(
  out: String,
  nodes: List(String),
  result: capture.CaptureResult,
  privacy: types.Privacy,
) -> Result(Nil, String) {
  let manifest =
    codec.Manifest(
      schema_version: codec.schema_version,
      tool_version: version,
      capture_id: capture_id(),
      nodes: nodes,
      completeness: result.completeness,
      privacy: privacy,
      checksums: [],
    )
  case storage.save(out, manifest, result.events) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error(string.inspect(error))
  }
}

fn run_server(
  mode: api.ServerMode,
  archive_path: Option(String),
  port: Int,
) -> Int {
  case
    server.start(
      bind: "127.0.0.1",
      port: port,
      mode: mode,
      secret_key_base: random_secret(),
      static_root: Some(web_root()),
      archive_path: archive_path,
    )
  {
    Ok(Nil) -> 0
    Error(error) -> fail("server failed: " <> error, 2)
  }
}

fn read_cookie(cookie_file: Option(String)) -> Result(String, String) {
  case cookie_file {
    Some(path) -> read_cookie_file(path)
    None -> read_cookie_default()
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
    Error(error) ->
      fail(capture.failure_guidance(error), capture.failure_exit_code(error))
  }
}

fn fail(message: String, code: Int) -> Int {
  io.println_error("beamtrace: " <> message)
  code
}

fn help_text() -> String {
  "BeamTrace — BEAM causal workbench\n\n"
  <> "Usage:\n"
  <> "  beamtrace attach <node> [--web|--tui] [--port PORT] [--cookie-file PATH]\n"
  <> "  beamtrace capture [<node>[,<node>...]] --trigger Module:function/arity [--where AQL]\n"
  <> "                    [--profile NAME] [--max-roots 1..1000] [--preset PRESET] --out FILE\n"
  <> "  beamtrace record [--node NODE] --trigger Module:function/arity --out FILE\n"
  <> "                   [--profile NAME] [capture options] -- <gleam|mix|rebar3 command>\n"
  <> "  beamtrace open <file.beamtrace> [--web|--tui] [--port PORT]\n"
  <> "  beamtrace compare <left.beamtrace> <right.beamtrace>\n"
  <> "  beamtrace export <file.beamtrace> --format html|jsonl|mermaid|otlp\n"
  <> "  beamtrace serve [--port PORT]\n"
  <> "  beamtrace demo [--web|--tui|--no-ui] [--out PATH] [--port PORT]\n"
  <> "  beamtrace relay <https-hub-url> --enroll TOKEN\n"
  <> "                  [--node NODE --trigger Module:function/arity] [--where AQL]\n"
  <> "                  [--cookie-file PATH] [--max-roots 1..1000] [--preset PRESET]\n"
  <> "                  [--raw-grant-file PATH]\n"
  <> "  beamtrace tui [--server URL] [--session-cookie-file PATH]\n"
  <> "  beamtrace init | config check\n"
  <> "  beamtrace doctor [--json] | mcp\n\n"
  <> "Cookie values are accepted only through --cookie-file, BEAMTRACE_COOKIE, or a secure prompt."
}

@external(erlang, "beamtrace_cli_ffi", "read_cookie_file")
fn read_cookie_file(path: String) -> Result(String, String)

@external(erlang, "beamtrace_cli_ffi", "read_cookie_default")
fn read_cookie_default() -> Result(String, String)

@external(erlang, "beamtrace_cli_ffi", "write_text")
fn write_text(path: String, content: String) -> Result(Nil, String)

@external(erlang, "beamtrace_cli_ffi", "random_secret")
fn random_secret() -> String

@external(erlang, "beamtrace_cli_ffi", "capture_id")
fn capture_id() -> String

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
