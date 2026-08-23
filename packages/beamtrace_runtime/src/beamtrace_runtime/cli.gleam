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
  Attach(node: String, mode: UiMode, cookie_file: Option(String))
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
    node: String,
    trigger: Mfa,
    where_aql: Option(String),
    out: String,
    cookie_file: Option(String),
    max_roots: Int,
    preset: types.Preset,
    command: List(String),
  )
  Open(path: String, mode: UiMode)
  Compare(left: String, right: String)
  Export(path: String, format: ExportFormat)
  Serve
  Relay(hub_url: String, enrollment_token: String, target: Option(RelayTarget))
  Tui(server: Option(String))
  Doctor
  Mcp
  Help
  Version
}

pub type ParseError {
  ParseError(message: String, exit_code: Int)
}

type CaptureOptions {
  CaptureOptions(
    trigger: Option(Mfa),
    where_aql: Option(String),
    out: Option(String),
    cookie_file: Option(String),
    max_roots: Int,
    preset: types.Preset,
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
    ["capture", node, ..options] -> parse_capture(node, options)
    ["record", ..options] -> parse_record(options)
    ["open", path, ..options] -> parse_open(path, options)
    ["compare", left, right] -> Ok(Compare(left, right))
    ["export", path, "--format", format] ->
      parse_export_format(format)
      |> map_result(fn(format) { Export(path, format) })
    ["serve"] -> Ok(Serve)
    ["relay", hub_url, "--enroll", token, ..options] ->
      parse_relay(hub_url, token, options)
    ["tui"] -> Ok(Tui(None))
    ["tui", "--server", server] -> Ok(Tui(Some(server)))
    ["doctor"] -> Ok(Doctor)
    ["mcp"] -> Ok(Mcp)
    [known, ..]
      if known == "attach"
      || known == "capture"
      || known == "open"
      || known == "compare"
      || known == "export"
      || known == "relay"
      || known == "tui"
    -> Error(usage("invalid arguments for '" <> known <> "'"))
    [unknown, ..] -> Error(usage("unknown command '" <> unknown <> "'"))
  }
}

fn parse_relay(
  hub_url: String,
  token: String,
  options: List(String),
) -> Result(Command, ParseError) {
  use parsed <- try_result(parse_relay_options(
    options,
    RelayOptions(None, None, None, None, 1, types.Generic, None),
  ))
  use _ <- try_result(validate_where(parsed.where_aql))
  case parsed.node, parsed.trigger, options {
    None, None, [] -> Ok(Relay(hub_url, token, None))
    Some(node), Some(trigger), _ ->
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
  case parsed.node, parsed.trigger, parsed.out, command {
    None, _, _, _ -> Error(usage("record requires --node <node>"))
    _, None, _, _ ->
      Error(usage("record requires --trigger Module:function/arity"))
    _, _, None, _ -> Error(usage("record requires --out <file.beamtrace>"))
    _, _, _, [] -> Error(usage("record requires '-- <command>'"))
    Some(node), Some(trigger), Some(out), [_, ..] ->
      Ok(Record(
        node: node,
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
  parse_attach_options(options, Web, None)
  |> map_result(fn(parsed) {
    let #(mode, cookie_file) = parsed
    Attach(node, mode, cookie_file)
  })
}

fn parse_attach_options(
  options: List(String),
  mode: UiMode,
  cookie_file: Option(String),
) -> Result(#(UiMode, Option(String)), ParseError) {
  case options {
    [] -> Ok(#(mode, cookie_file))
    ["--web", ..rest] -> parse_attach_options(rest, Web, cookie_file)
    ["--tui", ..rest] -> parse_attach_options(rest, TuiMode, cookie_file)
    ["--cookie-file", path, ..rest] ->
      parse_attach_options(rest, mode, Some(path))
    [option, ..] -> Error(usage("unknown attach option '" <> option <> "'"))
  }
}

fn parse_capture(
  node: String,
  options: List(String),
) -> Result(Command, ParseError) {
  let initial = CaptureOptions(None, None, None, None, 1, types.Generic)
  use parsed <- try_result(parse_capture_options(options, initial))
  use _ <- try_result(validate_where(parsed.where_aql))
  case parsed.trigger, parsed.out {
    Some(trigger), Some(out) ->
      Ok(Capture(
        node: node,
        trigger: trigger,
        where_aql: parsed.where_aql,
        out: out,
        cookie_file: parsed.cookie_file,
        max_roots: parsed.max_roots,
        preset: parsed.preset,
      ))
    None, _ -> Error(usage("capture requires --trigger Module:function/arity"))
    _, None -> Error(usage("capture requires --out <file.beamtrace>"))
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
  case options {
    [] | ["--web"] -> Ok(Open(path, Web))
    ["--tui"] -> Ok(Open(path, TuiMode))
    [option, ..] -> Error(usage("unknown open option '" <> option <> "'"))
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

fn usage(message: String) -> ParseError {
  ParseError(message, 2)
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
