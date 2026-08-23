import beamtrace/aql
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

pub type Command {
  Attach(node: String, mode: UiMode, cookie_file: Option(String))
  Capture(
    node: String,
    trigger: Mfa,
    where_aql: Option(String),
    out: String,
    cookie_file: Option(String),
  )
  Record(command: List(String))
  Open(path: String, mode: UiMode)
  Compare(left: String, right: String)
  Export(path: String, format: ExportFormat)
  Serve
  Relay(hub_url: String, enrollment_token: String)
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
    ["record", "--", command, ..rest] -> Ok(Record([command, ..rest]))
    ["record", ..] -> Error(usage("record requires '-- <command>'"))
    ["open", path, ..options] -> parse_open(path, options)
    ["compare", left, right] -> Ok(Compare(left, right))
    ["export", path, "--format", format] ->
      parse_export_format(format)
      |> map_result(fn(format) { Export(path, format) })
    ["serve"] -> Ok(Serve)
    ["relay", hub_url, "--enroll", token] -> Ok(Relay(hub_url, token))
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
  let initial = CaptureOptions(None, None, None, None)
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
    [option, ..] -> Error(usage("unknown capture option '" <> option <> "'"))
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
