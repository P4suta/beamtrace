// SPDX-License-Identifier: Apache-2.0 OR MIT
import argv
import beamtrace/aql
import beamtrace/codec
import beamtrace/diff
import beamtrace/stats
import beamtrace/types
import beamtrace_runtime/api
import beamtrace_runtime/capture
import beamtrace_runtime/cli
import beamtrace_runtime/command
import beamtrace_runtime/export
import beamtrace_runtime/mcp
import beamtrace_runtime/relay_channel
import beamtrace_runtime/relay_client
import beamtrace_runtime/server
import beamtrace_runtime/storage
import beamtrace_runtime/team_config
import beamtrace_tui
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const version = "0.1.0"

pub fn main() {
  let arguments = argv.load().arguments
  let code = case cli.parse(arguments) {
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
    cli.Doctor -> {
      io.print(doctor())
      0
    }
    cli.Capture(node, trigger, where_aql, out, cookie_file) ->
      run_capture(node, trigger, where_aql, out, cookie_file)
    cli.Attach(node, mode, cookie_file) -> run_attach(node, mode, cookie_file)
    cli.Open(path, mode) -> run_open(path, mode)
    cli.Compare(left, right) -> run_compare(left, right)
    cli.Export(path, format) -> run_export(path, format)
    cli.Record(child) -> run_record(child)
    cli.Serve -> run_serve()
    cli.Relay(hub_url, enrollment_token) -> run_relay(hub_url, enrollment_token)
    cli.Tui(server_url) -> {
      let target = case server_url {
        Some(value) -> value
        None -> "http://127.0.0.1:4040"
      }
      beamtrace_tui.run_remote(target)
      0
    }
    cli.Mcp -> {
      mcp.run()
      0
    }
  }
}

fn run_relay(hub_url: String, enrollment_token: String) -> Int {
  let identity = relay_channel.new_identity()
  case relay_client.enroll(hub_url, enrollment_token, identity) {
    Error(error) ->
      fail("relay enrollment failed: " <> string.inspect(error), 2)
    Ok(receipt) -> {
      io.println("Enrolled relay " <> receipt.relay_id)
      io.println("Outbound channel: " <> receipt.channel_url)
      io.println("Relay channel connected; press Ctrl+C to stop.")
      case relay_client.run_channel(receipt, identity) {
        Ok(Nil) -> 0
        Error(reason) -> fail("relay channel stopped: " <> reason, 2)
      }
    }
  }
}

fn run_serve() -> Int {
  case team_config.load_environment() {
    Ok(None) -> run_server(api.Local, None)
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
) -> Int {
  use cookie <- result_or_exit(read_cookie(cookie_file))
  let cli.Mfa(module_, function_, arity) = trigger
  let core_trigger = types.Mfa(module_, function_, arity)
  use captured <- result_or_exit(capture.remote(
    node,
    cookie,
    core_trigger,
    30_000,
    capture.default_budget(),
  ))
  use result <- result_or_exit(apply_capture_filter(
    captured,
    where_aql,
    core_trigger,
  ))
  let manifest =
    codec.Manifest(
      schema_version: codec.schema_version,
      tool_version: version,
      capture_id: capture_id(),
      nodes: [node],
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

fn apply_capture_filter(
  captured: capture.CaptureResult,
  where_aql: Option(String),
  trigger: types.Mfa,
) -> Result(capture.CaptureResult, String) {
  case where_aql {
    None -> Ok(captured)
    Some(source) ->
      case aql.parse(source) {
        Ok(query) -> Ok(capture.filter_roots(captured, query, trigger))
        Error(error) ->
          Error(
            "invalid AQL at offset "
            <> int.to_string(error.offset)
            <> ": "
            <> error.message,
          )
      }
  }
}

fn run_attach(
  node: String,
  mode: cli.UiMode,
  cookie_file: Option(String),
) -> Int {
  use cookie <- result_or_exit(read_cookie(cookie_file))
  case capture.probe(node, cookie) {
    Error(error) -> fail("attach failed: " <> error, 2)
    Ok(otp) ->
      case mode {
        cli.TuiMode -> {
          io.println("Attached " <> node <> " (OTP " <> otp <> ").")
          beamtrace_tui.run_attached([], node)
          0
        }
        cli.Web -> {
          io.println("Attached " <> node <> " (OTP " <> otp <> ").")
          run_server(api.Local, None)
        }
      }
  }
}

fn run_open(path: String, mode: cli.UiMode) -> Int {
  case mode {
    cli.Web ->
      case storage.window(path, start: 0, limit: 1) {
        Error(error) ->
          fail("could not open trace: " <> string.inspect(error), 2)
        Ok(window) -> {
          io.println(path <> ": " <> int.to_string(window.total) <> " events")
          run_server(api.Local, Some(path))
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

fn run_record(child: List(String)) -> Int {
  case run_command(child) {
    Ok(#(status, output)) -> {
      io.print(output)
      status
    }
    Error(error) -> fail("record failed: " <> error, 2)
  }
}

fn run_server(mode: api.ServerMode, archive_path: Option(String)) -> Int {
  io.println("BeamTrace workspace: http://127.0.0.1:4040")
  case
    server.start(
      bind: "127.0.0.1",
      port: 4040,
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

fn fail(message: String, code: Int) -> Int {
  io.println_error("beamtrace: " <> message)
  code
}

fn help_text() -> String {
  "BeamTrace — BEAM causal workbench\n\n"
  <> "Usage:\n"
  <> "  beamtrace attach <node> [--web|--tui] [--cookie-file PATH]\n"
  <> "  beamtrace capture <node> --trigger Module:function/arity [--where AQL] --out FILE\n"
  <> "  beamtrace record [options] -- <gleam|mix|rebar3 command>\n"
  <> "  beamtrace open <file.beamtrace> [--web|--tui]\n"
  <> "  beamtrace compare <left.beamtrace> <right.beamtrace>\n"
  <> "  beamtrace export <file.beamtrace> --format html|jsonl|mermaid|otlp\n"
  <> "  beamtrace serve | relay | tui | doctor | mcp\n\n"
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
fn doctor() -> String

@external(erlang, "beamtrace_cli_ffi", "run_command")
fn run_command(command: List(String)) -> Result(#(Int, String), String)

@external(erlang, "beamtrace_cli_ffi", "halt")
fn halt(code: Int) -> Nil
