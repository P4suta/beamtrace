import beamtrace/aql
import beamtrace/mfa as core_mfa
import beamtrace/types
import beamtrace_runtime/cli_spec
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Mfa {
  Mfa(module: String, function: String, arity: Int)
}

pub type UiMode {
  Web
  WebNoOpen
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
  DemoWebNoOpen
  DemoTui
  DemoNoUi
}

pub type CompareDisplay {
  CompareAuto
  CompareTerminal
  CompareWeb
  CompareWebNoOpen
  CompareTui
}

/// Resolve the implicit compare display the way record does: an interactive
/// terminal opens the Web comparison workspace, a pipe or CI keeps the
/// classic terminal output. Explicit modes pass through unchanged.
pub fn resolve_compare_display(
  display: CompareDisplay,
  interactive interactive: Bool,
) -> CompareDisplay {
  case display, interactive {
    CompareAuto, True -> CompareWeb
    CompareAuto, False -> CompareTerminal
    explicit, _ -> explicit
  }
}

pub type RecordDisplay {
  RecordWeb
  RecordWebNoOpen
  RecordTui
  RecordNoUi
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
    window_s: Int,
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
    window_s: Int,
  )
  Open(path: String, mode: UiMode, port: Int)
  CompareMany(paths: List(String), display: CompareDisplay, port: Int)
  Export(path: String, format: ExportFormat, otlp_anchor_now: Bool)
  Validate(path: String, json: Bool)
  Migrate(path: String, output: String)
  Serve(port: Int)
  ServeNoOpen(port: Int)
  Demo(mode: DemoMode, out: String, port: Int)
  Relay(hub_url: String, enrollment_token: String, target: Option(RelayTarget))
  Tui(server: Option(String), session_cookie_file: Option(String))
  Init
  ConfigCheck
  Doctor(json: Bool)
  Mcp
  Guide
  Help
  CommandHelp(name: String)
  Completion(shell: String)
  Version
  Json(command: Command)
  Force(command: Command)
  RecordUi(command: Command, display: RecordDisplay)
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
    window_s: Int,
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
    display: Option(RecordDisplay),
    window_s: Int,
  )
}

/// Default and bounds of `--capture-window SECONDS`.
pub const default_window_s = 30

const max_window_s = 300

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

type ParsedCompare {
  ParsedCompare(
    paths: List(String),
    display: CompareDisplay,
    explicit_display: Bool,
    port: Int,
    port_set: Bool,
  )
}

pub fn parse(arguments: List(String)) -> Result(Command, ParseError) {
  case list.contains(arguments, "--cookie") {
    True ->
      Error(ParseError(
        "--cookie is forbidden; use --cookie-file, the environment, or the secure prompt",
        4,
      ))
    False -> {
      let #(cleaned, json, force) = extract_global_options(arguments)
      case help_request(cleaned) {
        Some(None) -> Ok(Help)
        Some(Some(name)) -> command_help(name)
        None ->
          case check_option_values(cleaned) {
            Error(error) -> Error(error)
            Ok(Nil) ->
              case parse_command(cleaned) {
                Error(error) -> Error(error)
                Ok(command) -> wrap_global_options(command, json, force)
              }
          }
      }
    }
  }
}

/// `--help`/`-h` anywhere before the child separator asks for the help of
/// the first command word (or the root guide).
fn help_request(arguments: List(String)) -> Option(Option(String)) {
  help_request_loop(arguments, None)
}

fn help_request_loop(
  arguments: List(String),
  command: Option(String),
) -> Option(Option(String)) {
  case arguments {
    [] | ["--", ..] -> None
    ["--help", ..] | ["-h", ..] -> Some(command)
    [token, ..rest] ->
      case command, string.starts_with(token, "--") {
        None, False -> help_request_loop(rest, Some(token))
        _, _ -> help_request_loop(rest, command)
      }
  }
}

/// Reject a value-taking option whose value is missing or looks like another
/// option before any command parser runs.
fn check_option_values(arguments: List(String)) -> Result(Nil, ParseError) {
  case arguments {
    [command, ..rest] -> check_option_values_loop(command, rest)
    [] -> Ok(Nil)
  }
}

fn check_option_values_loop(
  command: String,
  arguments: List(String),
) -> Result(Nil, ParseError) {
  case arguments {
    [] | ["--", ..] -> Ok(Nil)
    [token, ..rest] ->
      case cli_spec.option_takes_value(command, token) {
        None -> check_option_values_loop(command, rest)
        Some(placeholder) ->
          case rest {
            [value, ..after] ->
              case value != "" && !string.starts_with(value, "--") {
                True -> check_option_values_loop(command, after)
                False -> Error(missing_value(token, placeholder))
              }
            [] -> Error(missing_value(token, placeholder))
          }
      }
  }
}

fn missing_value(option: String, placeholder: String) -> ParseError {
  usage("option '" <> option <> "' requires a value (" <> placeholder <> ")")
}

/// Split the tokens before `--` into positional arguments and option tokens
/// so flags may appear in any order.
fn split_positionals(
  command: String,
  arguments: List(String),
) -> #(List(String), List(String)) {
  split_positionals_loop(command, arguments, [], [])
}

fn split_positionals_loop(
  command: String,
  arguments: List(String),
  positionals: List(String),
  options: List(String),
) -> #(List(String), List(String)) {
  case arguments {
    [] -> #(list.reverse(positionals), list.reverse(options))
    [token, ..rest] ->
      case string.starts_with(token, "--") {
        False ->
          split_positionals_loop(command, rest, [token, ..positionals], options)
        True ->
          case cli_spec.option_takes_value(command, token), rest {
            Some(_), [value, ..after] ->
              split_positionals_loop(command, after, positionals, [
                value,
                token,
                ..options
              ])
            _, _ ->
              split_positionals_loop(command, rest, positionals, [
                token,
                ..options
              ])
          }
      }
  }
}

/// Whether execution still needs the one-time VM-global seq_trace approval.
/// Help, completion, and already acknowledged invocations never request it.
pub fn requires_seq_trace_ack(arguments: List(String)) -> Bool {
  case
    list.contains(arguments, "--acknowledge-seq-trace-reset"),
    invoked_command(arguments)
  {
    True, _ -> False
    _, "attach" | _, "capture" -> !list.contains(arguments, "--help")
    _, "relay" ->
      list.contains(arguments, "--node") && !list.contains(arguments, "--help")
    _, _ -> False
  }
}

/// Add the non-persistent approval flag after an interactive confirmation.
pub fn add_seq_trace_ack(arguments: List(String)) -> List(String) {
  list.append(arguments, ["--acknowledge-seq-trace-reset"])
}

/// Whether the common JSON contract was requested before a record child
/// command delimiter. Child arguments are never interpreted as BeamTrace
/// options.
pub fn json_requested(arguments: List(String)) -> Bool {
  case arguments {
    [] | ["--", ..] -> False
    ["--json", ..] -> True
    [_, ..rest] -> json_requested(rest)
  }
}

/// The first command word exactly as typed, for the `invoked` envelope field.
pub fn invoked_token(arguments: List(String)) -> Option(String) {
  case arguments {
    [] | ["--", ..] -> None
    ["--json", ..rest] | ["--force", ..rest] -> invoked_token(rest)
    [name, ..] -> Some(name)
  }
}

/// Stable command name for a parse-error JSON envelope: a specified command
/// name, or `unknown`.
pub fn invoked_command(arguments: List(String)) -> String {
  case arguments {
    [] -> "guide"
    ["--json", ..rest] | ["--force", ..rest] -> invoked_command(rest)
    ["--", ..] -> "record"
    [name, ..] ->
      case cli_spec.known(name) {
        True -> name
        False -> "unknown"
      }
  }
}

fn parse_command(arguments: List(String)) -> Result(Command, ParseError) {
  case arguments {
    [] -> Ok(Guide)
    ["help"] | ["--help"] | ["-h"] -> Ok(Help)
    ["help", "errors"] -> Ok(CommandHelp("errors"))
    ["help", "aql"] -> Ok(CommandHelp("aql"))
    ["help", command] -> command_help(command)
    ["version"] | ["--version"] | ["-V"] -> Ok(Version)
    ["completion", shell] -> parse_completion(shell)
    ["attach", ..rest] ->
      case split_positionals("attach", rest) {
        #([node], options) -> parse_attach(node, options)
        _ -> Error(usage("attach requires exactly one <node>"))
      }
    ["capture", ..options] -> parse_capture_command(options)
    ["record", ..options] -> parse_record(options)
    ["open", ..rest] ->
      case split_positionals("open", rest) {
        #([path], options) -> parse_open(path, options)
        _ -> Error(usage("open requires exactly one <file.beamtrace>"))
      }
    ["compare", ..options] -> parse_compare(options)
    ["export", ..rest] ->
      case split_positionals("export", rest) {
        #([path], options) -> parse_export(path, options, None, False)
        _ -> Error(usage("export requires exactly one <file.beamtrace>"))
      }
    ["validate", ..rest] ->
      case split_positionals("validate", rest) {
        #([path], []) -> Ok(Validate(path, False))
        #([_], [option, ..]) -> Error(unknown_option("validate", option))
        _ -> Error(usage("validate requires exactly one <file.beamtrace>"))
      }
    ["migrate", ..rest] ->
      case split_positionals("migrate", rest) {
        #([path], options) -> parse_migrate(path, options, None)
        _ -> Error(usage("migrate requires exactly one <v1.beamtrace>"))
      }
    ["serve", ..options] -> parse_serve(options, 0, False)
    ["demo", ..options] -> parse_demo(options, DemoWeb, "", 0)
    ["relay", hub_url, "--enroll", token, ..options] ->
      parse_relay(hub_url, token, options)
    ["relay", ..] ->
      Error(usage("relay requires <https-hub-url> --enroll TOKEN"))
    ["tui", ..options] -> parse_tui(options, None, None)
    ["init"] -> Ok(Init)
    ["config", "check"] -> Ok(ConfigCheck)
    ["doctor"] -> Ok(Doctor(False))
    ["mcp"] -> Ok(Mcp)
    [known, ..] ->
      case cli_spec.known(known) {
        True -> Error(usage("invalid arguments for '" <> known <> "'"))
        False -> Error(unknown_command(known))
      }
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
    [option, ..] -> Error(unknown_option("tui", option))
  }
}

fn parse_compare(options: List(String)) -> Result(Command, ParseError) {
  use parsed <- try_result(parse_compare_options(
    options,
    ParsedCompare([], CompareAuto, False, 0, False),
  ))
  let paths = list.reverse(parsed.paths)
  let count = list.length(paths)
  case count >= 2 && count <= 20 {
    False -> Error(usage("compare requires between 2 and 20 .beamtrace files"))
    True -> Ok(CompareMany(paths, parsed.display, parsed.port))
  }
}

fn parse_compare_options(
  options: List(String),
  parsed: ParsedCompare,
) -> Result(ParsedCompare, ParseError) {
  case options {
    [] -> Ok(parsed)
    ["--web", ..rest] -> {
      use next <- try_result(set_compare_display(parsed, CompareWeb))
      parse_compare_options(rest, next)
    }
    ["--tui", ..rest] -> {
      use next <- try_result(set_compare_display(parsed, CompareTui))
      parse_compare_options(rest, next)
    }
    ["--no-open", ..rest] -> {
      use next <- try_result(set_compare_display(parsed, CompareWebNoOpen))
      parse_compare_options(rest, next)
    }
    ["--port", value, ..rest] -> {
      use port <- try_result(parse_port(value))
      let display = case parsed.display {
        CompareAuto -> CompareWeb
        current -> current
      }
      case display == CompareTui {
        True -> Error(usage("--port cannot be used with --tui"))
        False ->
          parse_compare_options(
            rest,
            ParsedCompare(
              ..parsed,
              display: display,
              port: port,
              port_set: True,
            ),
          )
      }
    }
    [path, ..rest] ->
      case string.starts_with(path, "--") {
        True -> Error(unknown_option("compare", path))
        False ->
          parse_compare_options(
            rest,
            ParsedCompare(..parsed, paths: [path, ..parsed.paths]),
          )
      }
  }
}

fn set_compare_display(
  parsed: ParsedCompare,
  display: CompareDisplay,
) -> Result(ParsedCompare, ParseError) {
  case
    parsed.port_set && display == CompareTui,
    parsed.explicit_display,
    parsed.display == display
  {
    True, _, _ -> Error(usage("--port cannot be used with --tui"))
    _, True, False ->
      Error(usage("choose only one of --web, --tui, or --no-open"))
    _, _, _ ->
      Ok(ParsedCompare(..parsed, display: display, explicit_display: True))
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
    ["--enroll", _, ..rest] -> parse_relay_options(rest, parsed)
    [option, ..] -> Error(unknown_option("relay", option))
  }
}

fn parse_record(options: List(String)) -> Result(Command, ParseError) {
  parse_record_options(
    options,
    RecordOptions(
      None,
      None,
      None,
      None,
      None,
      1,
      types.Generic,
      None,
      default_window_s,
    ),
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
    ["--web", ..rest] -> {
      use display <- try_result(set_record_display(parsed.display, RecordWeb))
      parse_record_options(
        rest,
        RecordOptions(..parsed, display: Some(display)),
      )
    }
    ["--tui", ..rest] -> {
      use display <- try_result(set_record_display(parsed.display, RecordTui))
      parse_record_options(
        rest,
        RecordOptions(..parsed, display: Some(display)),
      )
    }
    ["--no-ui", ..rest] -> {
      use display <- try_result(set_record_display(parsed.display, RecordNoUi))
      parse_record_options(
        rest,
        RecordOptions(..parsed, display: Some(display)),
      )
    }
    ["--no-open", ..rest] -> {
      use display <- try_result(set_record_display(
        parsed.display,
        RecordWebNoOpen,
      ))
      parse_record_options(
        rest,
        RecordOptions(..parsed, display: Some(display)),
      )
    }
    ["--profile", _, ..rest] -> parse_record_options(rest, parsed)
    ["--capture-window", value, ..rest] -> {
      use window_s <- try_result(parse_window(value))
      parse_record_options(rest, RecordOptions(..parsed, window_s: window_s))
    }
    [option, ..] -> Error(unknown_option("record", option))
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
    _, _, [] -> Error(usage("record requires '-- <command>'"))
    Some(trigger), out, [_, ..] -> {
      let command =
        Record(
          node: parsed.node,
          trigger: trigger,
          where_aql: parsed.where_aql,
          out: case out {
            Some(path) -> path
            None -> ""
          },
          cookie_file: parsed.cookie_file,
          max_roots: parsed.max_roots,
          preset: parsed.preset,
          command: command,
          window_s: parsed.window_s,
        )
      case parsed.display {
        None -> Ok(command)
        Some(display) -> Ok(RecordUi(command, display))
      }
    }
  }
}

fn set_record_display(
  current: Option(RecordDisplay),
  requested: RecordDisplay,
) -> Result(RecordDisplay, ParseError) {
  case current {
    None -> Ok(requested)
    Some(value) if value == requested -> Ok(requested)
    Some(RecordWeb) if requested == RecordWebNoOpen -> Ok(RecordWebNoOpen)
    Some(RecordWebNoOpen) if requested == RecordWeb -> Ok(RecordWebNoOpen)
    Some(_) ->
      Error(usage("choose only one of --web, --tui, --no-ui, or --no-open"))
  }
}

fn parse_attach(
  node: String,
  options: List(String),
) -> Result(Command, ParseError) {
  use parsed <- try_result(parse_attach_options(options, Web, None, 0, False))
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
      parse_attach_options(
        rest,
        case mode {
          WebNoOpen -> WebNoOpen
          _ -> Web
        },
        cookie_file,
        port,
        acknowledged,
      )
    ["--tui", ..rest] ->
      case mode {
        WebNoOpen -> Error(usage("--no-open cannot be used with --tui"))
        _ ->
          parse_attach_options(rest, TuiMode, cookie_file, port, acknowledged)
      }
    ["--no-open", ..rest] ->
      case mode {
        TuiMode -> Error(usage("--no-open cannot be used with --tui"))
        _ ->
          parse_attach_options(rest, WebNoOpen, cookie_file, port, acknowledged)
      }
    ["--cookie-file", path, ..rest] ->
      parse_attach_options(rest, mode, Some(path), port, acknowledged)
    ["--port", value, ..rest] -> {
      use port <- try_result(parse_port(value))
      parse_attach_options(rest, mode, cookie_file, port, acknowledged)
    }
    ["--acknowledge-seq-trace-reset", ..rest] ->
      parse_attach_options(rest, mode, cookie_file, port, True)
    [option, ..] -> Error(unknown_option("attach", option))
  }
}

fn parse_capture(
  node: Option(String),
  options: List(String),
) -> Result(Command, ParseError) {
  let initial =
    CaptureOptions(
      node,
      None,
      None,
      None,
      None,
      1,
      types.Generic,
      False,
      default_window_s,
    )
  use parsed <- try_result(parse_capture_options(options, initial))
  use _ <- try_result(validate_where(parsed.where_aql))
  case parsed.node, parsed.trigger {
    Some(node), Some(trigger) ->
      case parsed.acknowledge_seq_trace_reset {
        False -> Error(seq_trace_acknowledgement_error())
        True ->
          Ok(Capture(
            node: node,
            trigger: trigger,
            where_aql: parsed.where_aql,
            out: case parsed.out {
              Some(path) -> path
              None -> ""
            },
            cookie_file: parsed.cookie_file,
            max_roots: parsed.max_roots,
            preset: parsed.preset,
            window_s: parsed.window_s,
          ))
      }
    None, _ -> Error(usage("capture requires a node or --node <node>"))
    _, None -> Error(usage("capture requires --trigger Module:function/arity"))
  }
}

fn validate_where(source: Option(String)) -> Result(Nil, ParseError) {
  case source {
    None -> Ok(Nil)
    Some(source) ->
      case aql.parse_for(source, fields: aql.event_fields()) {
        Ok(_) -> Ok(Nil)
        Error(error) ->
          Error(usage("invalid AQL: " <> aql.error_message(error)))
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
    ["--profile", _, ..rest] -> parse_capture_options(rest, parsed)
    ["--capture-window", value, ..rest] -> {
      use window_s <- try_result(parse_window(value))
      parse_capture_options(rest, CaptureOptions(..parsed, window_s: window_s))
    }
    [option, ..] -> Error(unknown_option("capture", option))
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
  case core_mfa.parse(source) {
    Ok(value) -> Ok(Mfa(value.module, value.function, value.arity))
    Error(error) ->
      Error(usage(
        "invalid MFA '" <> source <> "': " <> core_mfa.error_message(error),
      ))
  }
}

fn parse_open(
  path: String,
  options: List(String),
) -> Result(Command, ParseError) {
  parse_open_options(path, options, Web, 0)
}

fn parse_open_options(
  path: String,
  options: List(String),
  mode: UiMode,
  port: Int,
) -> Result(Command, ParseError) {
  case options {
    [] -> Ok(Open(path, mode, port))
    ["--web", ..rest] ->
      parse_open_options(
        path,
        rest,
        case mode {
          WebNoOpen -> WebNoOpen
          _ -> Web
        },
        port,
      )
    ["--tui", ..rest] ->
      case mode {
        WebNoOpen -> Error(usage("--no-open cannot be used with --tui"))
        _ -> parse_open_options(path, rest, TuiMode, port)
      }
    ["--no-open", ..rest] ->
      case mode {
        TuiMode -> Error(usage("--no-open cannot be used with --tui"))
        _ -> parse_open_options(path, rest, WebNoOpen, port)
      }
    ["--port", value, ..rest] -> {
      use port <- try_result(parse_port(value))
      parse_open_options(path, rest, mode, port)
    }
    [option, ..] -> Error(unknown_option("open", option))
  }
}

fn parse_serve(
  options: List(String),
  port: Int,
  no_open: Bool,
) -> Result(Command, ParseError) {
  case options {
    [] ->
      case no_open {
        True -> Ok(ServeNoOpen(port))
        False -> Ok(Serve(port))
      }
    ["--port", value, ..rest] -> {
      use port <- try_result(parse_port(value))
      parse_serve(rest, port, no_open)
    }
    ["--no-open", ..rest] -> parse_serve(rest, port, True)
    [option, ..] -> Error(unknown_option("serve", option))
  }
}

fn parse_migrate(
  path: String,
  options: List(String),
  output: Option(String),
) -> Result(Command, ParseError) {
  case options {
    [] ->
      case output {
        Some(output) -> Ok(Migrate(path, output))
        None -> Error(usage("migrate requires --output <v2.beamtrace>"))
      }
    ["--output", value, ..rest] -> parse_migrate(path, rest, Some(value))
    [option, ..] -> Error(unknown_option("migrate", option))
  }
}

fn parse_window(value: String) -> Result(Int, ParseError) {
  case int.parse(value) {
    Ok(seconds) if seconds >= 1 && seconds <= max_window_s -> Ok(seconds)
    _ ->
      Error(usage(
        "--capture-window must be between 1 and "
        <> int.to_string(max_window_s)
        <> " seconds",
      ))
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
    ["--web", ..rest] ->
      parse_demo(
        rest,
        case mode {
          DemoWebNoOpen -> DemoWebNoOpen
          _ -> DemoWeb
        },
        out,
        port,
      )
    ["--tui", ..rest] ->
      case mode {
        DemoWebNoOpen ->
          Error(usage("--no-open is only valid with the Web demo"))
        _ -> parse_demo(rest, DemoTui, out, port)
      }
    ["--no-ui", ..rest] ->
      case mode {
        DemoWebNoOpen ->
          Error(usage("--no-open is only valid with the Web demo"))
        _ -> parse_demo(rest, DemoNoUi, out, port)
      }
    ["--no-open", ..rest] ->
      case mode {
        DemoTui | DemoNoUi ->
          Error(usage("--no-open is only valid with the Web demo"))
        _ -> parse_demo(rest, DemoWebNoOpen, out, port)
      }
    ["--out", path, ..rest] if path != "" -> parse_demo(rest, mode, path, port)
    ["--port", value, ..rest] -> {
      use port <- try_result(parse_port(value))
      parse_demo(rest, mode, out, port)
    }
    [option, ..] -> Error(unknown_option("demo", option))
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
  options: List(String),
  format: Option(ExportFormat),
  anchor_now: Bool,
) -> Result(Command, ParseError) {
  case options {
    [] ->
      case format, anchor_now {
        None, _ ->
          Error(usage("export requires --format html|jsonl|mermaid|otlp"))
        Some(Otlp), _ -> Ok(Export(path, Otlp, anchor_now))
        Some(_), True ->
          Error(usage("--otlp-anchor-now is only valid with --format otlp"))
        Some(format), False -> Ok(Export(path, format, False))
      }
    ["--format", value, ..rest] -> {
      use format <- try_result(parse_export_format(value))
      parse_export(path, rest, Some(format), anchor_now)
    }
    ["--otlp-anchor-now", ..rest] -> parse_export(path, rest, format, True)
    [option, ..] -> Error(unknown_option("export", option))
  }
}

fn extract_global_options(
  arguments: List(String),
) -> #(List(String), Bool, Bool) {
  extract_global_options_loop(arguments, [], False, False)
}

fn extract_global_options_loop(
  arguments: List(String),
  accumulator: List(String),
  json: Bool,
  force: Bool,
) -> #(List(String), Bool, Bool) {
  case arguments {
    [] -> #(list.reverse(accumulator), json, force)
    ["--", ..child] -> #(
      list.append(list.reverse(accumulator), ["--", ..child]),
      json,
      force,
    )
    ["--json", ..rest] ->
      extract_global_options_loop(rest, accumulator, True, force)
    ["--force", ..rest] ->
      extract_global_options_loop(rest, accumulator, json, True)
    [argument, ..rest] ->
      extract_global_options_loop(rest, [argument, ..accumulator], json, force)
  }
}

fn wrap_global_options(
  command: Command,
  json: Bool,
  force: Bool,
) -> Result(Command, ParseError) {
  let forced = case force, force_capable(command), force_allowed(command) {
    False, _, _ -> Ok(command)
    True, True, True -> Ok(Force(command))
    True, True, False -> Error(usage("--force requires an explicit --out path"))
    True, False, _ ->
      Error(usage("--force is only valid for capture or record"))
  }
  use forced <- try_result(forced)
  case json, json_allowed(command) {
    False, _ -> Ok(forced)
    True, True -> Ok(Json(forced))
    True, False ->
      Error(usage(
        "--json is not available for interactive or long-running commands",
      ))
  }
}

fn force_allowed(command: Command) -> Bool {
  case command {
    Capture(out: out, ..) -> out != ""
    Record(out: out, ..) -> out != ""
    RecordUi(inner, _) -> force_allowed(inner)
    _ -> False
  }
}

fn force_capable(command: Command) -> Bool {
  case command {
    Capture(..) | Record(..) -> True
    RecordUi(inner, _) -> force_capable(inner)
    _ -> False
  }
}

fn json_allowed(command: Command) -> Bool {
  case command {
    Capture(..)
    | Record(..)
    | Export(..)
    | Validate(..)
    | Migrate(..)
    | Init
    | ConfigCheck
    | Doctor(..)
    | Version -> True
    CompareMany(_, CompareAuto, _) | CompareMany(_, CompareTerminal, _) -> True
    Demo(DemoNoUi, _, _) -> True
    RecordUi(_, RecordNoUi) -> True
    _ -> False
  }
}

fn command_help(command: String) -> Result(Command, ParseError) {
  case cli_spec.command_help(command) {
    Some(_) -> Ok(CommandHelp(command))
    None -> Error(unknown_command(command))
  }
}

fn parse_completion(shell: String) -> Result(Command, ParseError) {
  case cli_spec.completion(string.lowercase(shell)) {
    Some(_) -> Ok(Completion(string.lowercase(shell)))
    None ->
      Error(usage("completion shell must be bash, zsh, fish, or powershell"))
  }
}

fn unknown_option(command: String, option: String) -> ParseError {
  let correction = case cli_spec.suggest_option(command, option) {
    Some(candidate) -> ". Did you mean '" <> candidate <> "'?"
    None -> ""
  }
  usage("unknown " <> command <> " option '" <> option <> "'" <> correction)
}

fn unknown_command(command: String) -> ParseError {
  let correction = case cli_spec.suggest(command) {
    Some(candidate) ->
      ". Did you mean '"
      <> candidate
      <> "'? Try: beamtrace "
      <> candidate
      <> " --help"
    None -> ""
  }
  usage("unknown command '" <> command <> "'" <> correction)
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
