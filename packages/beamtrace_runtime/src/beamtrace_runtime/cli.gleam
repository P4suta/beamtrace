import beamtrace/aql
import beamtrace/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Mfa {
  Mfa(module_: String, function_: String, arity: Int)
}

pub type UiMode {
  Web
  TuiMode
}

pub type ExportFormat {
  Html
  Jsonl
  Mermaid
  Otlp
}

pub type DemoMode {
  DemoWeb
  DemoTui
  DemoNoUi
}

pub type RelayTarget {
  RelayTarget(
    node: String,
    trigger: Mfa,
    where_aql: Option(String),
    cookie_file: Option(String),
    max_roots: Int,
    preset: types.Preset,
    raw_grant_file: Option(String),
  )
}

pub type Command {
  Attach(node: String, mode: UiMode, cookie_file: Option(String), port: Int)
  Capture(
    node: String,
    trigger: Mfa,
    where_aql: Option(String),
    out: String,
    cookie_file: Option(String),
    max_roots: Int,
    preset: types.Preset,
  )
  Record(
    node: Option(String),
    trigger: Mfa,
    where_aql: Option(String),
    out: String,
    cookie_file: Option(String),
    max_roots: Int,
    preset: types.Preset,
    command: List(String),
  )
  Open(path: String, mode: UiMode, port: Int)
  Compare(left: String, right: String)
  Export(path: String, format: ExportFormat, otlp_anchor_now: Bool)
  Validate(path: String, json: Bool)
  Migrate(path: String, output: String)
  Serve(port: Int)
  Demo(mode: DemoMode, out: String, port: Int)
  Relay(hub_url: String, enrollment_token: String, target: Option(RelayTarget))
  Tui(server: Option(String), session_cookie_file: Option(String))
  Init
  ConfigCheck
  Doctor(json: Bool)
  Mcp
  Help
  Version
}

pub type ParseError {
  ParseError(message: String, exit_code: Int)
}

type CaptureOptions {
  CaptureOptions(
    node: Option(String),
    trigger: Option(Mfa),
    where_aql: Option(String),
    out: Option(String),
    cookie_file: Option(String),
    max_roots: Int,
    preset: types.Preset,
    acknowledge_seq_trace_reset: Bool,
  )
}

type RecordOptions {
  RecordOptions(
    node: Option(String),
    trigger: Option(Mfa),
    where_aql: Option(String),
    out: Option(String),
    cookie_file: Option(String),
    max_roots: Int,
    preset: types.Preset,
  )
}

type RelayOptions {
  RelayOptions(
    node: Option(String),
    trigger: Option(Mfa),
    where_aql: Option(String),
    cookie_file: Option(String),
    max_roots: Int,
    preset: types.Preset,
    raw_grant_file: Option(String),
    acknowledge_seq_trace_reset: Bool,
  )
}

pub fn parse(arguments: List(String)) -> Result(Command, ParseError) {
  case list.contains(arguments, "--cookie") {
    True ->
      Error(ParseError(
        "--cookie is forbidden; use --cookie-file, the environment, or the secure prompt",
        4,
      ))
    False -> parse_command(arguments)
  }
}

fn parse_command(arguments: List(String)) -> Result(Command, ParseError) {
  case arguments {
    [] -> Error(usage("a command is required"))
    ["help"] | ["--help"] | ["-h"] -> Ok(Help)
    ["version"] | ["--version"] | ["-V"] -> Ok(Version)
    ["attach", node, ..options] -> parse_attach(node, options)
    ["capture", ..options] -> parse_capture_command(options)
    ["record", ..options] -> parse_record(options)
    ["open", path, ..options] -> parse_open(path, options)
    ["compare", left, right] -> Ok(Compare(left, right))
    ["export", path, "--format", format, ..options] ->
      parse_export(path, format, options)
    ["export", path, "--otlp-anchor-now", "--format", format] ->
      parse_export(path, format, ["--otlp-anchor-now"])
    ["validate", path] -> Ok(Validate(path, False))
    ["validate", path, "--json"] | ["validate", "--json", path] ->
      Ok(Validate(path, True))
    ["migrate", path, "--output", output] -> Ok(Migrate(path, output))
    ["serve", ..options] -> parse_serve(options)
    ["demo", ..options] ->
      parse_demo(options, DemoWeb, "beamtrace-demo.beamtrace", 4040)
    ["relay", hub_url, "--enroll", token, ..options] ->
      parse_relay(hub_url, token, options)
    ["tui", ..options] -> parse_tui(options, None, None)
    ["init"] -> Ok(Init)
    ["config", "check"] -> Ok(ConfigCheck)
    ["doctor"] -> Ok(Doctor(False))
    ["doctor", "--json"] -> Ok(Doctor(True))
    ["mcp"] -> Ok(Mcp)
    [known, ..]
      if known == "attach"
      || known == "capture"
      || known == "record"
      || known == "open"
      || known == "compare"
      || known == "export"
      || known == "validate"
      || known == "migrate"
      || known == "relay"
      || known == "tui"
      || known == "serve"
      || known == "config"
      || known == "doctor"
      || known == "demo"
    -> Error(usage("invalid arguments for '" <> known <> "'"))
    [unknown, ..] -> Error(usage("unknown command '" <> unknown <> "'"))
  }
}

fn parse_tui(
  options: List(String),
  server: Option(String),
  session_cookie_file: Option(String),
) -> Result(Command, ParseError) {
  case options {
    [] -> Ok(Tui(server, session_cookie_file))
    ["--server", value, ..rest] ->
      parse_tui(rest, Some(value), session_cookie_file)
    ["--session-cookie-file", value, ..rest] ->
      parse_tui(rest, server, Some(value))
    [option, ..] -> Error(usage("unknown tui option '" <> option <> "'"))
  }
}

fn parse_capture_command(
  arguments: List(String),
) -> Result(Command, ParseError) {
  case arguments {
    [] -> parse_capture(None, [])
    [first, ..rest] ->
      case string.starts_with(first, "--") {
        True -> parse_capture(None, arguments)
        False -> parse_capture(Some(first), rest)
      }
  }
}

fn parse_relay(
  hub_url: String,
  token: String,
  options: List(String),
) -> Result(Command, ParseError) {
  use parsed <- try_result(parse_relay_options(
    options,
    RelayOptions(None, None, None, None, 1, types.Generic, None, False),
  ))
  use _ <- try_result(validate_where(parsed.where_aql))
  case parsed.node, parsed.trigger, options {
    None, None, [] -> Ok(Relay(hub_url, token, None))
    Some(node), Some(trigger), _ ->
      case parsed.acknowledge_seq_trace_reset {
        False -> Error(seq_trace_acknowledgement_error())
        True ->
          Ok(Relay(
            hub_url,
            token,
            Some(RelayTarget(
              node,
              trigger,
              parsed.where_aql,
              parsed.cookie_file,
              parsed.max_roots,
              parsed.preset,
              parsed.raw_grant_file,
            )),
          ))
      }
    None, _, _ -> Error(usage("relay producer requires --node <node>"))
    _, None, _ ->
      Error(usage("relay producer requires --trigger Module:function/arity"))
  }
}

fn parse_relay_options(
  options: List(String),
  parsed: RelayOptions,
) -> Result(RelayOptions, ParseError) {
  case options {
    [] -> Ok(parsed)
    ["--node", value, ..rest] ->
      parse_relay_options(rest, RelayOptions(..parsed, node: Some(value)))
    ["--trigger", value, ..rest] -> {
      use trigger <- try_result(parse_mfa(value))
      parse_relay_options(rest, RelayOptions(..parsed, trigger: Some(trigger)))
    }
    ["--where", value, ..rest] ->
      parse_relay_options(rest, RelayOptions(..parsed, where_aql: Some(value)))
    ["--cookie-file", value, ..rest] ->
      parse_relay_options(
        rest,
        RelayOptions(..parsed, cookie_file: Some(value)),
      )
    ["--raw-grant-file", value, ..rest] ->
      case string.trim(value) == "" {
        True -> Error(usage("--raw-grant-file requires a path"))
        False ->
          parse_relay_options(
            rest,
            RelayOptions(..parsed, raw_grant_file: Some(value)),
          )
      }
    ["--acknowledge-seq-trace-reset", ..rest] ->
      parse_relay_options(
        rest,
        RelayOptions(..parsed, acknowledge_seq_trace_reset: True),
      )
    ["--max-roots", value, ..rest] ->
      case int.parse(value) {
        Ok(max_roots) if max_roots >= 1 && max_roots <= 1000 ->
          parse_relay_options(
            rest,
            RelayOptions(..parsed, max_roots: max_roots),
          )
        _ -> Error(usage("--max-roots must be between 1 and 1000"))
      }
    ["--preset", value, ..rest] -> {
      use preset <- try_result(parse_capture_preset(value))
      parse_relay_options(rest, RelayOptions(..parsed, preset: preset))
    }
    [option, ..] -> Error(usage("unknown relay option '" <> option <> "'"))
  }
}

fn parse_record(options: List(String)) -> Result(Command, ParseError) {
  parse_record_options(
    options,
    RecordOptions(None, None, None, None, None, 1, types.Generic),
  )
}

fn parse_record_options(
  options: List(String),
  parsed: RecordOptions,
) -> Result(Command, ParseError) {
  case options {
    ["--", command, ..rest] -> finish_record(parsed, [command, ..rest])
    ["--"] -> Error(usage("record requires '-- <command>'"))
    [] -> Error(usage("record requires '-- <command>'"))
    ["--node", value, ..rest] ->
      parse_record_options(rest, RecordOptions(..parsed, node: Some(value)))
    ["--trigger", value, ..rest] -> {
      use trigger <- try_result(parse_mfa(value))
      parse_record_options(
        rest,
        RecordOptions(..parsed, trigger: Some(trigger)),
      )
    }
    ["--where", value, ..rest] ->
      parse_record_options(
        rest,
        RecordOptions(..parsed, where_aql: Some(value)),
      )
    ["--out", value, ..rest] ->
      parse_record_options(rest, RecordOptions(..parsed, out: Some(value)))
    ["--cookie-file", value, ..rest] ->
      parse_record_options(
        rest,
        RecordOptions(..parsed, cookie_file: Some(value)),
      )
    ["--max-roots", value, ..rest] ->
      case int.parse(value) {
        Ok(max_roots) if max_roots >= 1 && max_roots <= 1000 ->
          parse_record_options(
            rest,
            RecordOptions(..parsed, max_roots: max_roots),
          )
        _ -> Error(usage("--max-roots must be between 1 and 1000"))
      }
    ["--preset", value, ..rest] -> {
      use preset <- try_result(parse_capture_preset(value))
      parse_record_options(rest, RecordOptions(..parsed, preset: preset))
    }
    [option, ..] -> Error(usage("unknown record option '" <> option <> "'"))
  }
}

fn finish_record(
  parsed: RecordOptions,
  command: List(String),
) -> Result(Command, ParseError) {
  use _ <- try_result(validate_where(parsed.where_aql))
  case parsed.trigger, parsed.out, command {
    None, _, _ ->
      Error(usage("record requires --trigger Module:function/arity"))
    _, None, _ -> Error(usage("record requires --out <file.beamtrace>"))
    _, _, [] -> Error(usage("record requires '-- <command>'"))
    Some(trigger), Some(out), [_, ..] ->
      Ok(Record(
        node: parsed.node,
        trigger: trigger,
        where_aql: parsed.where_aql,
        out: out,
        cookie_file: parsed.cookie_file,
        max_roots: parsed.max_roots,
        preset: parsed.preset,
        command: command,
      ))
  }
}

fn parse_attach(
  node: String,
  options: List(String),
) -> Result(Command, ParseError) {
  use parsed <- try_result(parse_attach_options(options, Web, None, 4040, False))
  let #(mode, cookie_file, port, acknowledged) = parsed
  case acknowledged {
    True -> Ok(Attach(node, mode, cookie_file, port))
    False -> Error(seq_trace_acknowledgement_error())
  }
}

fn parse_attach_options(
  options: List(String),
  mode: UiMode,
  cookie_file: Option(String),
  port: Int,
  acknowledged: Bool,
) -> Result(#(UiMode, Option(String), Int, Bool), ParseError) {
  case options {
    [] -> Ok(#(mode, cookie_file, port, acknowledged))
    ["--web", ..rest] ->
      parse_attach_options(rest, Web, cookie_file, port, acknowledged)
    ["--tui", ..rest] ->
      parse_attach_options(rest, TuiMode, cookie_file, port, acknowledged)
    ["--cookie-file", path, ..rest] ->
      parse_attach_options(rest, mode, Some(path), port, acknowledged)
    ["--port", value, ..rest] -> {
      use port <- try_result(parse_port(value))
      parse_attach_options(rest, mode, cookie_file, port, acknowledged)
    }
    ["--acknowledge-seq-trace-reset", ..rest] ->
      parse_attach_options(rest, mode, cookie_file, port, True)
    [option, ..] -> Error(usage("unknown attach option '" <> option <> "'"))
  }
}

fn parse_capture(
  node: Option(String),
  options: List(String),
) -> Result(Command, ParseError) {
  let initial =
    CaptureOptions(node, None, None, None, None, 1, types.Generic, False)
  use parsed <- try_result(parse_capture_options(options, initial))
  use _ <- try_result(validate_where(parsed.where_aql))
  case parsed.node, parsed.trigger, parsed.out {
    Some(node), Some(trigger), Some(out) ->
      case parsed.acknowledge_seq_trace_reset {
        False -> Error(seq_trace_acknowledgement_error())
        True ->
          Ok(Capture(
            node: node,
            trigger: trigger,
            where_aql: parsed.where_aql,
            out: out,
            cookie_file: parsed.cookie_file,
            max_roots: parsed.max_roots,
            preset: parsed.preset,
          ))
      }
    None, _, _ -> Error(usage("capture requires a node or --node <node>"))
    _, None, _ ->
      Error(usage("capture requires --trigger Module:function/arity"))
    _, _, None -> Error(usage("capture requires --out <file.beamtrace>"))
  }
}

fn validate_where(source: Option(String)) -> Result(Nil, ParseError) {
  case source {
    None -> Ok(Nil)
    Some(source) ->
      case aql.parse(source) {
        Ok(_) -> Ok(Nil)
        Error(error) ->
          Error(usage(
            "invalid AQL at offset "
            <> int.to_string(error.offset)
            <> ": "
            <> error.message,
          ))
      }
  }
}

fn parse_capture_options(
  options: List(String),
  parsed: CaptureOptions,
) -> Result(CaptureOptions, ParseError) {
  case options {
    [] -> Ok(parsed)
    ["--node", value, ..rest] ->
      parse_capture_options(rest, CaptureOptions(..parsed, node: Some(value)))
    ["--trigger", value, ..rest] -> {
      use mfa <- try_result(parse_mfa(value))
      parse_capture_options(rest, CaptureOptions(..parsed, trigger: Some(mfa)))
    }
    ["--where", value, ..rest] ->
      parse_capture_options(
        rest,
        CaptureOptions(..parsed, where_aql: Some(value)),
      )
    ["--out", value, ..rest] ->
      parse_capture_options(rest, CaptureOptions(..parsed, out: Some(value)))
    ["--cookie-file", value, ..rest] ->
      parse_capture_options(
        rest,
        CaptureOptions(..parsed, cookie_file: Some(value)),
      )
    ["--max-roots", value, ..rest] ->
      case int.parse(value) {
        Ok(max_roots) if max_roots >= 1 && max_roots <= 1000 ->
          parse_capture_options(
            rest,
            CaptureOptions(..parsed, max_roots: max_roots),
          )
        _ -> Error(usage("--max-roots must be between 1 and 1000"))
      }
    ["--preset", value, ..rest] -> {
      use preset <- try_result(parse_capture_preset(value))
      parse_capture_options(rest, CaptureOptions(..parsed, preset: preset))
    }
    ["--acknowledge-seq-trace-reset", ..rest] ->
      parse_capture_options(
        rest,
        CaptureOptions(..parsed, acknowledge_seq_trace_reset: True),
      )
    [option, ..] -> Error(usage("unknown capture option '" <> option <> "'"))
  }
}

fn parse_capture_preset(source: String) -> Result(types.Preset, ParseError) {
  case string.lowercase(source) {
    "generic" -> Ok(types.Generic)
    "gleam-actor" -> Ok(types.GleamActor)
    "wisp-mist" -> Ok(types.WispMist)
    "gen-server" -> Ok(types.GenServer)
    "phoenix" -> Ok(types.Phoenix)
    "erlang-supervisor" -> Ok(types.ErlangSupervisor)
    _ -> Error(usage("unknown capture preset '" <> source <> "'"))
  }
}

pub fn parse_mfa(source: String) -> Result(Mfa, ParseError) {
  case string.split(source, on: ":") {
    [module_, function_and_arity] if module_ != "" ->
      case string.split(function_and_arity, on: "/") {
        [function_, arity_source] if function_ != "" ->
          case int.parse(arity_source) {
            Ok(arity) if arity >= 0 -> Ok(Mfa(module_, function_, arity))
            _ -> Error(usage("invalid MFA '" <> source <> "'"))
          }
        _ -> Error(usage("invalid MFA '" <> source <> "'"))
      }
    _ -> Error(usage("invalid MFA '" <> source <> "'"))
  }
}

fn parse_open(
  path: String,
  options: List(String),
) -> Result(Command, ParseError) {
  parse_open_options(path, options, Web, 4040)
}

fn parse_open_options(
  path: String,
  options: List(String),
  mode: UiMode,
  port: Int,
) -> Result(Command, ParseError) {
  case options {
    [] -> Ok(Open(path, mode, port))
    ["--web", ..rest] -> parse_open_options(path, rest, Web, port)
    ["--tui", ..rest] -> parse_open_options(path, rest, TuiMode, port)
    ["--port", value, ..rest] -> {
      use port <- try_result(parse_port(value))
      parse_open_options(path, rest, mode, port)
    }
    [option, ..] -> Error(usage("unknown open option '" <> option <> "'"))
  }
}

fn parse_serve(options: List(String)) -> Result(Command, ParseError) {
  case options {
    [] -> Ok(Serve(4040))
    ["--port", value] -> parse_port(value) |> map_result(Serve)
    [option, ..] -> Error(usage("unknown serve option '" <> option <> "'"))
  }
}

fn parse_port(value: String) -> Result(Int, ParseError) {
  case int.parse(value) {
    Ok(port) if port >= 0 && port <= 65_535 -> Ok(port)
    _ -> Error(usage("--port must be between 0 and 65535"))
  }
}

fn parse_demo(
  options: List(String),
  mode: DemoMode,
  out: String,
  port: Int,
) -> Result(Command, ParseError) {
  case options {
    [] -> Ok(Demo(mode, out, port))
    ["--web", ..rest] -> parse_demo(rest, DemoWeb, out, port)
    ["--tui", ..rest] -> parse_demo(rest, DemoTui, out, port)
    ["--no-ui", ..rest] -> parse_demo(rest, DemoNoUi, out, port)
    ["--out", path, ..rest] if path != "" -> parse_demo(rest, mode, path, port)
    ["--port", value, ..rest] -> {
      use port <- try_result(parse_port(value))
      parse_demo(rest, mode, out, port)
    }
    [option, ..] -> Error(usage("unknown demo option '" <> option <> "'"))
  }
}

fn parse_export_format(source: String) -> Result(ExportFormat, ParseError) {
  case source {
    "html" -> Ok(Html)
    "jsonl" -> Ok(Jsonl)
    "mermaid" -> Ok(Mermaid)
    "otlp" -> Ok(Otlp)
    _ -> Error(usage("unknown export format '" <> source <> "'"))
  }
}

fn parse_export(
  path: String,
  format_source: String,
  options: List(String),
) -> Result(Command, ParseError) {
  use format <- try_result(parse_export_format(format_source))
  case format, options {
    _, [] -> Ok(Export(path, format, False))
    Otlp, ["--otlp-anchor-now"] -> Ok(Export(path, format, True))
    _, ["--otlp-anchor-now"] ->
      Error(usage("--otlp-anchor-now is only valid with --format otlp"))
    _, [option, ..] -> Error(usage("unknown export option '" <> option <> "'"))
  }
}

fn usage(message: String) -> ParseError {
  ParseError(message, 2)
}

fn seq_trace_acknowledgement_error() -> ParseError {
  ParseError(
    "exact attach capture acquires the VM-global seq_trace lease and resets "
      <> "its label during cleanup; re-run with --acknowledge-seq-trace-reset",
    4,
  )
}

fn try_result(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn map_result(result: Result(a, e), transform: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(transform(value))
    Error(error) -> Error(error)
  }
}
