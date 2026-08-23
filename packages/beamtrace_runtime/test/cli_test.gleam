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
    "--cookie-file",
    ".secrets/cookie",
  ])
  |> should.equal(
    Ok(cli.Capture(
      node: "shop@127.0.0.1",
      trigger: cli.Mfa("shop", "checkout", 2),
      where_aql: Some("message.tag == \"$gen_call\""),
      out: "checkout.beamtrace",
      cookie_file: Some(".secrets/cookie"),
    )),
  )
}

pub fn every_public_command_parses_test() {
  [
    cli.parse(["attach", "app@host", "--web"]),
    cli.parse(["record", "--", "gleam", "run"]),
    cli.parse(["open", "run.beamtrace", "--tui"]),
    cli.parse(["compare", "good.beamtrace", "bad.beamtrace"]),
    cli.parse(["export", "run.beamtrace", "--format", "mermaid"]),
    cli.parse(["serve"]),
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

pub fn plaintext_cookie_argument_is_a_safety_refusal_test() {
  let assert Error(error) =
    cli.parse(["attach", "app@host", "--cookie", "secret"])
  error.exit_code |> should.equal(4)
  error.message
  |> should.equal(
    "--cookie is forbidden; use --cookie-file, the environment, or the secure prompt",
  )
}

pub fn defaults_do_not_smuggle_a_cookie_test() {
  cli.parse(["attach", "app@host"])
  |> should.equal(Ok(cli.Attach("app@host", cli.Web, None)))
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
