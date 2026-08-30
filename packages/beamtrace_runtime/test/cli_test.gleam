import beamtrace/types
import beamtrace_runtime/cli
import beamtrace_runtime/cli_spec
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn every_help_form_uses_the_declarative_command_spec_test() {
  cli.parse([]) |> should.equal(Ok(cli.Guide))
  cli.parse(["help"]) |> should.equal(Ok(cli.Help))
  cli.parse(["help", "--help"])
  |> should.equal(Ok(cli.CommandHelp("help")))
  cli.parse(["help", "version"])
  |> should.equal(Ok(cli.CommandHelp("version")))
  cli.parse(["version", "--help"])
  |> should.equal(Ok(cli.CommandHelp("version")))
  cli.parse(["config", "check", "--help"])
  |> should.equal(Ok(cli.CommandHelp("config")))

  let assert Some(capture_help) = cli_spec.command_help("capture")
  capture_help
  |> string.split(on: "--cookie-file PATH")
  |> list.length
  |> should.equal(2)
}

pub fn force_requires_an_explicit_archive_destination_test() {
  let assert Error(capture_error) =
    cli.parse([
      "capture",
      "app@host",
      "--trigger",
      "app:run/0",
      "--acknowledge-seq-trace-reset",
      "--force",
    ])
  capture_error.message
  |> should.equal("--force requires an explicit --out path")

  let assert Ok(cli.Force(cli.Record(..))) =
    cli.parse([
      "record",
      "--trigger",
      "app:run/0",
      "--out",
      "explicit.beamtrace",
      "--force",
      "--",
      "gleam",
      "run",
    ])
}

pub fn capture_command_contract_test() {
  cli.parse([
    "capture",
    "shop@127.0.0.1",
    "--trigger",
    "shop:checkout/2",
    "--where",
    "message.tag == \"$gen_call\"",
    "--out",
    "checkout.beamtrace",
    "--max-roots",
    "3",
    "--preset",
    "gen-server",
    "--cookie-file",
    ".secrets/cookie",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.equal(
    Ok(cli.Capture(
      node: "shop@127.0.0.1",
      trigger: cli.Mfa("shop", "checkout", 2),
      where_aql: Some("message.tag == \"$gen_call\""),
      out: "checkout.beamtrace",
      cookie_file: Some(".secrets/cookie"),
      max_roots: 3,
      preset: types.GenServer,
      window_s: 30,
    )),
  )
}

pub fn capture_defaults_to_one_generic_root_test() {
  cli.parse([
    "capture",
    "app@host",
    "--trigger",
    "shop:checkout/1",
    "--out",
    "x.beamtrace",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.equal(
    Ok(cli.Capture(
      node: "app@host",
      trigger: cli.Mfa("shop", "checkout", 1),
      where_aql: None,
      out: "x.beamtrace",
      cookie_file: None,
      max_roots: 1,
      preset: types.Generic,
      window_s: 30,
    )),
  )
}

pub fn capture_accepts_an_option_node_for_project_profile_expansion_test() {
  cli.parse([
    "capture",
    "--node",
    "profile@host",
    "--trigger",
    "shop:checkout/1",
    "--out",
    "x.beamtrace",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.equal(
    Ok(cli.Capture(
      node: "profile@host",
      trigger: cli.Mfa("shop", "checkout", 1),
      where_aql: None,
      out: "x.beamtrace",
      cookie_file: None,
      max_roots: 1,
      preset: types.Generic,
      window_s: 30,
    )),
  )
}

pub fn capture_rejects_invalid_root_budget_and_preset_test() {
  let base = [
    "capture",
    "app@host",
    "--trigger",
    "shop:checkout/1",
    "--out",
    "x.beamtrace",
  ]
  let assert Error(root_error) =
    cli.parse(list.append(base, ["--max-roots", "0"]))
  root_error.exit_code |> should.equal(2)
  root_error.message |> should.equal("--max-roots must be between 1 and 1000")

  let assert Error(preset_error) =
    cli.parse(list.append(base, ["--preset", "magic"]))
  preset_error.exit_code |> should.equal(2)
  preset_error.message |> should.equal("unknown capture preset 'magic'")
}

pub fn every_public_command_parses_test() {
  [
    cli.parse([
      "attach",
      "app@host",
      "--web",
      "--acknowledge-seq-trace-reset",
    ]),
    cli.parse([
      "record",
      "--node",
      "app@host",
      "--trigger",
      "shop:checkout/1",
      "--out",
      "run.beamtrace",
      "--",
      "gleam",
      "run",
    ]),
    cli.parse(["open", "run.beamtrace", "--tui"]),
    cli.parse(["compare", "good.beamtrace", "bad.beamtrace"]),
    cli.parse(["export", "run.beamtrace", "--format", "mermaid"]),
    cli.parse(["serve"]),
    cli.parse(["demo", "--no-ui", "--out", "demo.beamtrace"]),
    cli.parse(["init"]),
    cli.parse(["config", "check"]),
    cli.parse(["relay", "https://hub.example", "--enroll", "once"]),
    cli.parse(["tui", "--server", "http://127.0.0.1:4040"]),
    cli.parse(["doctor"]),
    cli.parse(["mcp"]),
  ]
  |> list.all(fn(result) {
    case result {
      Ok(_) -> True
      Error(_) -> False
    }
  })
  |> should.be_true()
}

pub fn demo_parses_ui_output_and_ephemeral_port_test() {
  cli.parse([
    "demo",
    "--tui",
    "--out",
    "custom.beamtrace",
    "--port",
    "0",
  ])
  |> should.equal(Ok(cli.Demo(cli.DemoTui, "custom.beamtrace", 0)))
}

pub fn no_open_is_an_order_independent_web_modifier_test() {
  let assert Ok(cli.RecordUi(_, cli.RecordWebNoOpen)) =
    cli.parse([
      "record",
      "--trigger",
      "app:run/0",
      "--no-open",
      "--web",
      "--",
      "gleam",
      "run",
    ])
  let assert Ok(cli.RecordUi(_, cli.RecordWebNoOpen)) =
    cli.parse([
      "record",
      "--trigger",
      "app:run/0",
      "--web",
      "--no-open",
      "--",
      "gleam",
      "run",
    ])

  cli.parse([
    "attach",
    "app@host",
    "--no-open",
    "--web",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.equal(Ok(cli.Attach("app@host", cli.WebNoOpen, None, 0)))
  cli.parse(["open", "trace.beamtrace", "--no-open", "--web"])
  |> should.equal(Ok(cli.Open("trace.beamtrace", cli.WebNoOpen, 0)))
  cli.parse(["demo", "--no-open", "--web"])
  |> should.equal(Ok(cli.Demo(cli.DemoWebNoOpen, "", 0)))
}

pub fn no_open_rejects_later_non_web_display_options_test() {
  let record =
    cli.parse([
      "record",
      "--trigger",
      "app:run/0",
      "--no-open",
      "--tui",
      "--",
      "gleam",
      "run",
    ])
  let assert Error(record_error) = record
  record_error.message |> string.contains("--no-open") |> should.be_true()

  [
    cli.parse([
      "attach",
      "app@host",
      "--no-open",
      "--tui",
      "--acknowledge-seq-trace-reset",
    ]),
    cli.parse(["open", "trace.beamtrace", "--no-open", "--tui"]),
    cli.parse(["demo", "--no-open", "--tui"]),
    cli.parse(["demo", "--no-open", "--no-ui"]),
  ]
  |> list.each(fn(result) {
    let assert Error(error) = result
    error.message |> string.contains("--no-open") |> should.be_true()
  })
}

pub fn team_tui_accepts_only_a_session_cookie_file_not_a_cookie_value_test() {
  cli.parse([
    "tui",
    "--server",
    "https://trace.example",
    "--session-cookie-file",
    ".secrets/team-session",
  ])
  |> should.equal(
    Ok(cli.Tui(Some("https://trace.example"), Some(".secrets/team-session"))),
  )

  cli.parse(["tui", "--session-cookie", "secret"])
  |> should.equal(
    Error(cli.ParseError(
      "unknown tui option '--session-cookie'. Did you mean '--session-cookie-file'?",
      2,
    )),
  )
}

pub fn relay_target_producer_parses_capture_options_without_plaintext_cookie_test() {
  cli.parse([
    "relay",
    "https://hub.example",
    "--enroll",
    "once",
    "--node",
    "app@host",
    "--trigger",
    "shop:checkout/1",
    "--where",
    "arg.0.tag == order",
    "--cookie-file",
    ".secrets/cookie",
    "--max-roots",
    "3",
    "--preset",
    "gen-server",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.equal(
    Ok(cli.Relay(
      "https://hub.example",
      "once",
      Some(cli.RelayTarget(
        "app@host",
        cli.Mfa("shop", "checkout", 1),
        Some("arg.0.tag == order"),
        Some(".secrets/cookie"),
        3,
        types.GenServer,
        None,
      )),
    )),
  )

  let assert Error(error) =
    cli.parse([
      "relay",
      "https://hub.example",
      "--enroll",
      "once",
      "--node",
      "app@host",
    ])
  error.message
  |> should.equal("relay producer requires --trigger Module:function/arity")
}

pub fn relay_raw_capture_accepts_only_a_grant_file_not_a_plaintext_token_test() {
  let assert Ok(cli.Relay(_, _, Some(target))) =
    cli.parse([
      "relay",
      "https://hub.example",
      "--enroll",
      "once",
      "--node",
      "app@host",
      "--trigger",
      "shop:checkout/1",
      "--raw-grant-file",
      ".secrets/raw-grant.json",
      "--acknowledge-seq-trace-reset",
    ])
  target.raw_grant_file |> should.equal(Some(".secrets/raw-grant.json"))

  let assert Error(error) =
    cli.parse([
      "relay",
      "https://hub.example",
      "--enroll",
      "once",
      "--node",
      "app@host",
      "--trigger",
      "shop:checkout/1",
      "--raw-grant",
      "plaintext-secret",
    ])
  error.message
  |> should.equal(
    "unknown relay option '--raw-grant'. Did you mean '--raw-grant-file'?",
  )
}

pub fn record_parses_capture_options_before_the_child_separator_test() {
  cli.parse([
    "record",
    "--node",
    "app@host",
    "--trigger",
    "shop:checkout/1",
    "--where",
    "arg.0.tag == order",
    "--out",
    "run.beamtrace",
    "--max-roots",
    "2",
    "--preset",
    "gleam-actor",
    "--cookie-file",
    ".secrets/cookie",
    "--",
    "gleam",
    "test",
  ])
  |> should.equal(
    Ok(cli.Record(
      node: Some("app@host"),
      trigger: cli.Mfa("shop", "checkout", 1),
      where_aql: Some("arg.0.tag == order"),
      out: "run.beamtrace",
      cookie_file: Some(".secrets/cookie"),
      max_roots: 2,
      preset: types.GleamActor,
      command: ["gleam", "test"],
      window_s: 30,
    )),
  )
}

pub fn record_generates_a_target_but_still_requires_trigger_output_and_child_test() {
  let assert Error(error) = cli.parse(["record", "--", "gleam", "test"])
  error.exit_code |> should.equal(2)
  error.message
  |> should.equal("record requires --trigger Module:function/arity")

  cli.parse([
    "record",
    "--trigger",
    "m:f/0",
    "--out",
    "x.beamtrace",
    "--",
    "gleam",
    "run",
  ])
  |> should.equal(
    Ok(cli.Record(
      None,
      cli.Mfa("m", "f", 0),
      None,
      "x.beamtrace",
      None,
      1,
      types.Generic,
      ["gleam", "run"],
      30,
    )),
  )

  let assert Error(child_error) =
    cli.parse([
      "record",
      "--node",
      "app@host",
      "--trigger",
      "m:f/0",
      "--out",
      "x.beamtrace",
      "--",
    ])
  child_error.message |> should.equal("record requires '-- <command>'")
}

pub fn plaintext_cookie_argument_is_a_safety_refusal_test() {
  let assert Error(error) =
    cli.parse(["attach", "app@host", "--cookie", "secret"])
  error.exit_code |> should.equal(4)
  error.message
  |> should.equal(
    "--cookie is forbidden; use --cookie-file, the environment, or the secure prompt",
  )
}

pub fn attach_requires_explicit_seq_trace_reset_acknowledgement_test() {
  let assert Error(error) = cli.parse(["attach", "app@host"])
  error.exit_code |> should.equal(4)
  error.message
  |> should.equal(
    "exact attach capture acquires the VM-global seq_trace lease and resets its label during cleanup; re-run with --acknowledge-seq-trace-reset",
  )

  cli.parse([
    "attach",
    "app@host",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.equal(Ok(cli.Attach("app@host", cli.Web, None, 0)))
}

pub fn local_web_commands_accept_ephemeral_or_explicit_ports_test() {
  cli.parse([
    "attach",
    "app@host",
    "--web",
    "--port",
    "0",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.equal(Ok(cli.Attach("app@host", cli.Web, None, 0)))
  cli.parse(["open", "trace.beamtrace", "--web", "--port", "8123"])
  |> should.equal(Ok(cli.Open("trace.beamtrace", cli.Web, 8123)))
  cli.parse(["serve", "--port", "0"])
  |> should.equal(Ok(cli.Serve(0)))

  let assert Error(error) = cli.parse(["serve", "--port", "65536"])
  error.message |> should.equal("--port must be between 0 and 65535")
}

pub fn malformed_mfa_is_usage_error_test() {
  let assert Error(error) =
    cli.parse([
      "capture",
      "app@host",
      "--trigger",
      "bad",
      "--out",
      "x.beamtrace",
    ])
  error.exit_code |> should.equal(2)
}

pub fn malformed_where_aql_is_rejected_during_cli_parsing_test() {
  let assert Error(error) =
    cli.parse([
      "capture",
      "app@host",
      "--trigger",
      "shop:checkout/1",
      "--where",
      "message.tag ==",
      "--out",
      "x.beamtrace",
    ])
  error.exit_code |> should.equal(2)
  error.message |> should.equal("invalid AQL at offset 14: expected value")
}

pub fn no_arguments_is_a_successful_short_guide_test() {
  cli.parse([]) |> should.equal(Ok(cli.Guide))
  cli_spec.short_guide()
  |> string.contains("beamtrace demo")
  |> should.be_true()
}

pub fn command_help_and_every_help_alias_come_from_the_spec_test() {
  cli.parse(["help", "capture"])
  |> should.equal(Ok(cli.CommandHelp("capture")))
  cli.parse(["capture", "--help"])
  |> should.equal(Ok(cli.CommandHelp("capture")))
  let assert Some(help) = cli_spec.command_help("capture")
  help |> string.contains("Defaults:") |> should.be_true()
  help |> string.contains("Examples:") |> should.be_true()
  help |> string.contains("--force") |> should.be_true()
}

pub fn typo_returns_nearest_command_and_correction_example_test() {
  let assert Error(error) = cli.parse(["comprae"])
  error.message
  |> string.contains("Did you mean 'compare'?")
  |> should.be_true()
  error.message
  |> string.contains("beamtrace compare --help")
  |> should.be_true()
}

pub fn completion_is_generated_for_all_supported_shells_test() {
  ["bash", "zsh", "fish", "powershell"]
  |> list.each(fn(shell) {
    cli.parse(["completion", shell])
    |> should.equal(Ok(cli.Completion(shell)))
    let assert Some(script) = cli_spec.completion(shell)
    script |> string.contains("beamtrace") |> should.be_true()
    script |> string.contains("capture") |> should.be_true()
  })

  let assert Some(zsh) = cli_spec.completion("zsh")
  zsh
  |> string.contains(
    "compare) _arguments '*:archive:_files -g \"*.beamtrace\"' '--web[Open the multi-run comparison workspace.]'",
  )
  |> should.be_true()
}

pub fn capture_and_record_generate_output_names_when_out_is_omitted_test() {
  cli.parse([
    "capture",
    "app@host",
    "--trigger",
    "m:f/0",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.equal(
    Ok(cli.Capture(
      "app@host",
      cli.Mfa("m", "f", 0),
      None,
      "",
      None,
      1,
      types.Generic,
      30,
    )),
  )

  let assert Ok(cli.Record(out: record_out, ..)) =
    cli.parse(["record", "--trigger", "m:f/0", "--", "gleam", "run"])
  record_out |> should.equal("")
}

pub fn force_json_record_modes_and_multi_compare_are_explicit_test() {
  let assert Ok(cli.Force(cli.Capture(out: "capture.beamtrace", ..))) =
    cli.parse([
      "capture",
      "app@host",
      "--trigger",
      "m:f/0",
      "--out",
      "capture.beamtrace",
      "--force",
      "--acknowledge-seq-trace-reset",
    ])

  let assert Ok(cli.Json(cli.CompareMany(paths, cli.CompareTerminal, 0))) =
    cli.parse([
      "compare",
      "one.beamtrace",
      "two.beamtrace",
      "three.beamtrace",
      "--json",
    ])
  list.length(paths) |> should.equal(3)

  let assert Ok(cli.RecordUi(_, cli.RecordNoUi)) =
    cli.parse([
      "record",
      "--trigger",
      "m:f/0",
      "--no-ui",
      "--",
      "gleam",
      "run",
    ])

  let assert Error(compare_mode_error) =
    cli.parse([
      "compare",
      "one.beamtrace",
      "two.beamtrace",
      "--tui",
      "--json",
    ])
  compare_mode_error.message
  |> should.equal(
    "--json is not available for interactive or long-running commands",
  )
}

pub fn seq_trace_confirmation_is_requested_only_for_unacknowledged_execution_test() {
  cli.requires_seq_trace_ack(["capture", "app@host", "--trigger", "m:f/0"])
  |> should.be_true()
  cli.requires_seq_trace_ack(["capture", "--help"])
  |> should.be_false()
  cli.requires_seq_trace_ack([
    "capture",
    "app@host",
    "--acknowledge-seq-trace-reset",
  ])
  |> should.be_false()
  cli.requires_seq_trace_ack([
    "--force",
    "capture",
    "app@host",
    "--trigger",
    "m:f/0",
  ])
  |> should.be_true()
  cli.requires_seq_trace_ack([
    "--json",
    "relay",
    "wss://hub.example/relay",
    "token",
    "--node",
    "app@host",
  ])
  |> should.be_true()
}

pub fn compare_rejects_port_and_tui_in_either_order_test() {
  [
    [
      "compare",
      "one.beamtrace",
      "two.beamtrace",
      "--port",
      "0",
      "--tui",
    ],
    [
      "compare",
      "one.beamtrace",
      "two.beamtrace",
      "--tui",
      "--port",
      "4040",
    ],
  ]
  |> list.each(fn(arguments) {
    let assert Error(error) = cli.parse(arguments)
    error.message |> should.equal("--port cannot be used with --tui")
  })
}

pub fn help_flag_is_accepted_anywhere_before_the_child_separator_test() {
  cli.parse(["record", "--trigger", "m:f/0", "--help"])
  |> should.equal(Ok(cli.CommandHelp("record")))
  cli.parse(["record", "--help", "--", "app", "--help"])
  |> should.equal(Ok(cli.CommandHelp("record")))
  cli.parse(["open", "x.beamtrace", "--help"])
  |> should.equal(Ok(cli.CommandHelp("open")))
  cli.parse(["capture", "app@host", "-h"])
  |> should.equal(Ok(cli.CommandHelp("capture")))
  cli.parse(["config", "check", "--help"])
  |> should.equal(Ok(cli.CommandHelp("config")))
  let assert Ok(cli.Record(command: child, ..)) =
    cli.parse(["record", "--trigger", "m:f/0", "--", "app", "--help"])
  child |> should.equal(["app", "--help"])
}

pub fn missing_option_value_is_reported_as_such_test() {
  let assert Error(trigger) = cli.parse(["record", "--trigger"])
  trigger.message |> should.equal("option '--trigger' requires a value (MFA)")
  let assert Error(port) = cli.parse(["open", "x.beamtrace", "--port"])
  port.message |> should.equal("option '--port' requires a value (PORT)")
  let assert Error(out) =
    cli.parse(["record", "--out", "--trigger", "m:f/0", "--", "x"])
  out.message |> should.equal("option '--out' requires a value (PATH)")
}

pub fn unknown_option_suggests_the_nearest_flag_test() {
  let assert Error(error) =
    cli.parse(["record", "--triger", "m:f/0", "--", "x"])
  error.message
  |> string.contains("unknown record option '--triger'")
  |> should.be_true()
  error.message
  |> string.contains("Did you mean '--trigger'?")
  |> should.be_true()
}

pub fn unique_command_prefix_is_suggested_test() {
  let assert Error(error) = cli.parse(["cap"])
  error.message
  |> string.contains("Did you mean 'capture'?")
  |> should.be_true()
  let assert Error(ambiguous) = cli.parse(["co"])
  ambiguous.message |> string.contains("Did you mean") |> should.be_false()
}

pub fn every_spec_command_is_recognised_by_the_parser_test() {
  list.each(cli_spec.names(), fn(name) {
    case cli.parse([name, "extra-positional", "--nonsense"]) {
      Error(error) ->
        error.message |> string.contains("unknown command") |> should.be_false()
      Ok(_) -> Nil
    }
  })
}

fn sample_option_value(placeholder: String) -> String {
  case placeholder {
    "PORT" -> "0"
    "N" -> "1"
    "MFA" -> "m:f/0"
    "NODE" -> "app@host"
    "PRESET" -> "generic"
    "FORMAT" -> "html"
    "URL" -> "http://127.0.0.1:4040"
    "SECONDS" -> "30"
    _ -> "x"
  }
}

fn reconciliation_bases() -> List(#(String, List(String))) {
  [
    #("attach", ["attach", "app@host", "--acknowledge-seq-trace-reset"]),
    #("capture", [
      "capture",
      "app@host",
      "--trigger",
      "m:f/0",
      "--acknowledge-seq-trace-reset",
    ]),
    #("record", ["record", "--trigger", "m:f/0"]),
    #("open", ["open", "x.beamtrace"]),
    #("compare", ["compare", "a.beamtrace", "b.beamtrace"]),
    #("export", ["export", "x.beamtrace", "--format", "otlp"]),
    #("validate", ["validate", "x.beamtrace"]),
    #("migrate", ["migrate", "old.beamtrace", "--output", "new.beamtrace"]),
    #("serve", ["serve"]),
    #("demo", ["demo", "--no-ui"]),
    #("relay", [
      "relay",
      "https://hub.example",
      "--enroll",
      "TOKEN",
      "--node",
      "app@host",
      "--trigger",
      "m:f/0",
      "--acknowledge-seq-trace-reset",
    ]),
    #("tui", ["tui"]),
    #("init", ["init"]),
    #("config", ["config", "check"]),
    #("doctor", ["doctor"]),
    #("version", ["version"]),
  ]
}

/// The drift gate: every flag the spec lists is accepted by the parser and
/// every flag the spec omits is rejected.
pub fn parser_and_spec_agree_on_every_option_test() {
  let all_flags =
    cli_spec.commands()
    |> list.flat_map(fn(spec) { spec.options })
    |> list.map(fn(option) { option.flag })
    |> list.unique
  list.each(reconciliation_bases(), fn(base) {
    let #(name, argv) = base
    let accepted = cli_spec.option_names(name)
    list.each(all_flags, fn(flag) {
      let option = cli_spec.option_name(flag)
      let tokens = case cli_spec.option_placeholder(flag) {
        None -> [option]
        Some(placeholder) -> [option, sample_option_value(placeholder)]
      }
      let full = case name {
        "record" -> list.flatten([argv, tokens, ["--", "x"]])
        _ -> list.append(argv, tokens)
      }
      let result = cli.parse(full)
      let rejected_as_unknown = case result {
        Error(error) ->
          string.contains(error.message, "unknown " <> name <> " option")
          || string.contains(error.message, "requires a value")
        Ok(_) -> False
      }
      case list.contains(accepted, option) {
        True ->
          case rejected_as_unknown {
            True -> panic as { name <> " rejects spec option " <> option }
            False -> Nil
          }
        False ->
          case result {
            Ok(_) -> panic as { name <> " accepts unlisted option " <> option }
            Error(_) -> Nil
          }
      }
    })
  })
}

pub fn every_help_example_parses_test() {
  cli_spec.commands()
  |> list.flat_map(fn(spec) { spec.examples })
  |> list.filter(fn(example) {
    !string.contains(example, ">") && !string.contains(example, "--profile")
  })
  |> list.each(fn(example) {
    let argv = case string.split(example, on: " ") {
      ["beamtrace", ..rest] -> rest
      other -> other
    }
    case cli.parse(argv) {
      Ok(_) -> Nil
      Error(cli.ParseError(_, 4)) -> Nil
      Error(error) -> panic as { example <> ": " <> error.message }
    }
  })
}
