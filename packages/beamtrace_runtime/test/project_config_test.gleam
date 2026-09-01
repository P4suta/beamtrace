// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/cli
import beamtrace_runtime/project_config
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should

pub fn project_profiles_apply_defaults_then_profile_then_explicit_cli_test() {
  let source =
    "[defaults]\n"
    <> "trigger = \"default:run/0\"\n"
    <> "out = \"traces/default.beamtrace\"\n"
    <> "max_roots = 2\n"
    <> "[profiles.dev]\n"
    <> "trigger = \"profile:run/1\"\n"
    <> "max_roots = 3\n"
  let assert Ok(configuration) =
    project_config.parse("/workspace/project/beamtrace.toml", source)
  let assert Ok(arguments) =
    project_config.prepare_with(Some(configuration), [
      "record",
      "--profile",
      "dev",
      "--trigger",
      "cli:run/2",
      "--",
      "gleam",
      "run",
      "--profile",
      "child-argument",
    ])

  arguments
  |> should.equal([
    "record",
    "--trigger",
    "default:run/0",
    "--out",
    "/workspace/project/traces/default.beamtrace",
    "--max-roots",
    "2",
    "--trigger",
    "profile:run/1",
    "--max-roots",
    "3",
    "--trigger",
    "cli:run/2",
    "--",
    "gleam",
    "run",
    "--profile",
    "child-argument",
  ])
}

pub fn capture_profile_supplies_node_and_positional_node_remains_highest_precedence_test() {
  let source =
    "[defaults]\n"
    <> "node = \"default@host\"\n"
    <> "trigger = \"default:run/0\"\n"
    <> "out = \"traces/default.beamtrace\"\n"
    <> "[profiles.dev]\n"
    <> "node = \"profile@host\"\n"
    <> "trigger = \"profile:run/1\"\n"
  let assert Ok(configuration) =
    project_config.parse("/workspace/project/beamtrace.toml", source)

  let assert Ok(profile_arguments) =
    project_config.prepare_with(Some(configuration), [
      "capture",
      "--profile",
      "dev",
      "--acknowledge-seq-trace-reset",
    ])
  let assert Ok(cli.Capture(node: profile_node, ..)) =
    cli.parse(profile_arguments)
  profile_node |> should.equal("profile@host")

  let assert Ok(explicit_arguments) =
    project_config.prepare_with(Some(configuration), [
      "capture",
      "explicit@host",
      "--profile",
      "dev",
      "--out",
      "explicit.beamtrace",
      "--acknowledge-seq-trace-reset",
    ])
  let assert Ok(cli.Capture(node: explicit_node, out: explicit_out, ..)) =
    cli.parse(explicit_arguments)
  explicit_node |> should.equal("explicit@host")
  explicit_out |> should.equal("explicit.beamtrace")
}

pub fn project_config_rejects_commands_and_all_secret_classes_test() {
  [
    "command = \"mix test\"",
    "cookie = \"secret\"",
    "raw_grant = \"secret\"",
    "oidc_client_secret = \"secret\"",
    "s3_access_key = \"secret\"",
  ]
  |> list.each(fn(field) {
    let assert Error(error) =
      project_config.parse(
        "/workspace/project/beamtrace.toml",
        "[profiles.bad]\n" <> field,
      )
    error |> string.contains("forbidden") |> should.be_true()
  })
}

pub fn project_config_validates_profile_capture_values_test() {
  [
    "trigger = \"not-an-mfa\"",
    "where = \"arg.0 ==\"",
    "preset = \"unknown-framework\"",
  ]
  |> list.each(fn(field) {
    let assert Error(error) =
      project_config.parse(
        "/workspace/project/beamtrace.toml",
        "[profiles.bad]\n" <> field,
      )
    error |> string.contains("invalid configuration value") |> should.be_true()
  })
}

pub fn project_config_reports_the_aql_offset_and_suggestion_test() {
  let assert Error(error) =
    project_config.parse(
      "/workspace/project/beamtrace.toml",
      "[profiles.bad]\nwhere = \"message.tga == 1\"",
    )
  error
  |> should.equal(
    "invalid configuration value for 'where': unknown field 'message.tga' at "
    <> "offset 0; did you mean 'message.tag'?",
  )
}

pub fn doctor_cookie_files_include_resolved_defaults_and_profiles_once_test() {
  let source =
    "[defaults]\n"
    <> "cookie_file = \"secrets/default.cookie\"\n"
    <> "[profiles.dev]\n"
    <> "cookie_file = \"secrets/dev.cookie\"\n"
    <> "[profiles.same]\n"
    <> "cookie_file = \"secrets/default.cookie\"\n"
  let assert Ok(configuration) =
    project_config.parse("/workspace/project/beamtrace.toml", source)
  let files = project_config.cookie_files(configuration)
  list.length(files) |> should.equal(2)
  files
  |> list.contains("/workspace/project/secrets/default.cookie")
  |> should.be_true()
  files
  |> list.contains("/workspace/project/secrets/dev.cookie")
  |> should.be_true()
}
