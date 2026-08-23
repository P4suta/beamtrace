import beamtrace_runtime/config
import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should

pub fn precedence_is_cli_env_project_user_default_test() {
  let cli = dict.from_list([#("port", "5001")])
  let env = dict.from_list([#("port", "5002"), #("bind", "127.0.0.2")])
  let project = dict.from_list([#("port", "5003"), #("bind", "127.0.0.3")])
  let user = dict.from_list([#("port", "5004"), #("bind", "127.0.0.4")])

  config.resolve(cli, env, project, user)
  |> should.equal(
    Ok(config.Config(
      bind: "127.0.0.2",
      port: 5001,
      team: False,
      cookie_file: None,
      retention_days: 7,
    )),
  )
}

pub fn cookie_file_may_come_from_cli_or_environment_test() {
  let assert Ok(resolved) =
    config.resolve(
      dict.from_list([#("cookie_file", "cli.cookie")]),
      dict.from_list([#("cookie_file", "env.cookie")]),
      dict.new(),
      dict.new(),
    )
  resolved.cookie_file |> should.equal(Some("cli.cookie"))
}

pub fn secret_values_are_rejected_in_toml_sources_test() {
  let project = dict.from_list([#("cookie", "forbidden")])
  config.resolve(dict.new(), dict.new(), project, dict.new())
  |> should.equal(Error(config.SecretInToml("cookie")))
}

pub fn invalid_port_is_not_silently_defaulted_test() {
  config.resolve(
    dict.from_list([#("port", "99999")]),
    dict.new(),
    dict.new(),
    dict.new(),
  )
  |> should.equal(Error(config.InvalidPort("99999")))
}
