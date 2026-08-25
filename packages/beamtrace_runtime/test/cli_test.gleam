import beamtrace/types
import beamtrace_runtime/cli
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

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
    Error(cli.ParseError("unknown tui option '--session-cookie'", 2)),
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
  error.message |> should.equal("unknown relay option '--raw-grant'")
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
    Ok(
      cli.Record(
        node: Some("app@host"),
        trigger: cli.Mfa("shop", "checkout", 1),
        where_aql: Some("arg.0.tag == order"),
        out: "run.beamtrace",
        cookie_file: Some(".secrets/cookie"),
        max_roots: 2,
        preset: types.GleamActor,
        command: ["gleam", "test"],
      ),
    ),
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
    Ok(
      cli.Record(
        None,
        cli.Mfa("m", "f", 0),
        None,
        "x.beamtrace",
        None,
        1,
        types.Generic,
        ["gleam", "run"],
      ),
    ),
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
  |> should.equal(Ok(cli.Attach("app@host", cli.Web, None, 4040)))
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
