//// Round-trip audit: every flag the declarative specification lists must be
//// accepted by the parser, and --json/--force acceptance must match the
//// specification exactly, so completion, help, and behaviour cannot drift.

// SPDX-License-Identifier: Apache-2.0 OR MIT

import beamtrace_runtime/cli
import beamtrace_runtime/cli_spec
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should

/// Minimal valid invocation per command, split around the child separator so
/// audited flags land before `--`.
fn base_arguments(command: String) -> Option(#(List(String), List(String))) {
  case command {
    "help" -> Some(#(["help"], []))
    "attach" -> Some(#(["attach", "app@host"], []))
    "capture" ->
      Some(
        #(
          [
            "capture", "app@host", "--trigger", "m:f/0", "--out", "x.beamtrace",
            "--acknowledge-seq-trace-reset",
          ],
          [],
        ),
      )
    "record" ->
      Some(
        #(["record", "--trigger", "m:f/0", "--out", "x.beamtrace"], [
          "--",
          "erl",
        ]),
      )
    "open" -> Some(#(["open", "x.beamtrace"], []))
    "compare" -> Some(#(["compare", "a.beamtrace", "b.beamtrace"], []))
    "export" -> Some(#(["export", "x.beamtrace", "--format", "html"], []))
    "validate" -> Some(#(["validate", "x.beamtrace"], []))
    "migrate" ->
      Some(#(["migrate", "x.beamtrace", "--output", "y.beamtrace"], []))
    "serve" -> Some(#(["serve"], []))
    "demo" -> Some(#(["demo"], []))
    "relay" -> Some(#(["relay", "https://hub.example", "--enroll", "tok"], []))
    "tui" -> Some(#(["tui"], []))
    "init" -> Some(#(["init"], []))
    "config" -> Some(#(["config", "check"], []))
    "doctor" -> Some(#(["doctor"], []))
    "mcp" -> Some(#(["mcp"], []))
    "completion" -> Some(#(["completion", "bash"], []))
    "version" -> Some(#(["version"], []))
    _ -> None
  }
}

fn dummy_value(flag: String, placeholder: String) -> String {
  case flag, placeholder {
    "--node", _ -> "app@host"
    "--trigger", _ -> "m:f/0"
    "--where", _ -> "exact == true"
    "--format", _ -> "html"
    "--preset", _ -> "generic"
    "--enroll", _ -> "tok"
    "--server", _ -> "https://hub.example"
    _, "N" -> "1"
    _, "PORT" -> "0"
    _, "SECONDS" -> "30"
    _, _ -> "x"
  }
}

fn arguments_for(command: String, flag: String) -> Option(List(String)) {
  use #(prefix, suffix) <- option.then(base_arguments(command))
  // --profile is consumed by project_config.prepare before cli.parse and is
  // covered by the project-config tests instead.
  use <- bool_guard(flag == "--profile", None)
  // The base for export already carries --format; re-adding it is still a
  // valid parse, as is repeating other value options.
  let addition = case cli_spec.option_takes_value(command, flag) {
    Some(placeholder) -> [flag, dummy_value(flag, placeholder)]
    None -> [flag]
  }
  Some(list.flatten([prefix, addition, suffix]))
}

fn bool_guard(condition: Bool, value: a, otherwise: fn() -> a) -> a {
  case condition {
    True -> value
    False -> otherwise()
  }
}

pub fn every_specified_flag_is_accepted_by_the_parser_test() {
  list.each(cli_spec.names(), fn(command) {
    list.each(cli_spec.command_option_flags(command), fn(flag) {
      case arguments_for(command, flag) {
        None -> Nil
        Some(arguments) ->
          case cli.parse(arguments) {
            Ok(_) -> Nil
            Error(error) ->
              case string.contains(error.message, "'" <> flag <> "'") {
                False -> Nil
                True ->
                  panic as {
                    command
                    <> " rejects its specified flag "
                    <> flag
                    <> ": "
                    <> error.message
                  }
              }
          }
      }
    })
  })
}

/// --json on demo additionally needs --no-ui: the specification documents
/// the flag, and this base is how a JSON invocation is actually written.
fn json_base_arguments(
  command: String,
) -> Option(#(List(String), List(String))) {
  case command {
    "demo" -> Some(#(["demo", "--no-ui"], []))
    _ -> base_arguments(command)
  }
}

pub fn json_and_force_acceptance_matches_the_specification_test() {
  list.each(cli_spec.names(), fn(command) {
    case json_base_arguments(command) {
      None -> Nil
      Some(#(prefix, suffix)) -> {
        let flags = cli_spec.command_option_flags(command)
        check_global(command, prefix, suffix, "--json", flags)
        check_global(command, prefix, suffix, "--force", flags)
      }
    }
  })
}

fn check_global(
  command: String,
  prefix: List(String),
  suffix: List(String),
  flag: String,
  flags: List(String),
) -> Nil {
  let accepted = case cli.parse(list.flatten([prefix, [flag], suffix])) {
    Ok(_) -> True
    Error(_) -> False
  }
  let specified = list.contains(flags, flag)
  case accepted == specified {
    True -> Nil
    False ->
      panic as {
        command
        <> " "
        <> flag
        <> ": specification says "
        <> render_bool(specified)
        <> " but the parser says "
        <> render_bool(accepted)
      }
  }
  should.be_true(accepted == specified)
}

fn render_bool(value: Bool) -> String {
  case value {
    True -> "accepted"
    False -> "rejected"
  }
}
