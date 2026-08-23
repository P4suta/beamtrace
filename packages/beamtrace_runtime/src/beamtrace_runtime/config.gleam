import gleam/dict.{type Dict}
import gleam/int
import gleam/option.{type Option, None, Some}

pub type Config {
  Config(
    bind: String,
    port: Int,
    team: Bool,
    cookie_file: Option(String),
    retention_days: Int,
  )
}

pub type ConfigError {
  SecretInToml(key: String)
  InvalidPort(value: String)
  InvalidBoolean(key: String, value: String)
  InvalidPositiveInteger(key: String, value: String)
}

/// Resolve configuration in the documented order. The project and user maps
/// represent parsed TOML; the environment map contains already-normalised
/// BEAMTRACE_* keys without the prefix.
pub fn resolve(
  cli: Dict(String, String),
  environment: Dict(String, String),
  project: Dict(String, String),
  user: Dict(String, String),
) -> Result(Config, ConfigError) {
  use _ <- try_result(reject_toml_secrets(project))
  use _ <- try_result(reject_toml_secrets(user))

  let port_source = first([cli, environment, project, user], "port", "4040")
  use port <- try_result(parse_port(port_source))

  let team_source = first([cli, environment, project, user], "team", "false")
  use team <- try_result(parse_bool("team", team_source))

  let retention_source =
    first([cli, environment, project, user], "retention_days", "7")
  use retention_days <- try_result(parse_positive(
    "retention_days",
    retention_source,
  ))

  let cookie_file =
    first_option([cli, environment, project, user], "cookie_file")

  Ok(Config(
    bind: first([cli, environment, project, user], "bind", "127.0.0.1"),
    port: port,
    team: team,
    cookie_file: cookie_file,
    retention_days: retention_days,
  ))
}

fn reject_toml_secrets(
  source: Dict(String, String),
) -> Result(Nil, ConfigError) {
  first_forbidden(
    [
      "cookie",
      "cookie_value",
      "enrollment_token",
      "relay_private_key",
      "oidc_client_secret",
      "bootstrap_token",
    ],
    source,
  )
}

fn first_forbidden(
  keys: List(String),
  source: Dict(String, String),
) -> Result(Nil, ConfigError) {
  case keys {
    [] -> Ok(Nil)
    [key, ..rest] ->
      case dict.has_key(source, key) {
        True -> Error(SecretInToml(key))
        False -> first_forbidden(rest, source)
      }
  }
}

fn first(
  sources: List(Dict(String, String)),
  key: String,
  default: String,
) -> String {
  case first_option(sources, key) {
    Some(value) -> value
    None -> default
  }
}

fn first_option(
  sources: List(Dict(String, String)),
  key: String,
) -> Option(String) {
  case sources {
    [] -> None
    [source, ..rest] ->
      case dict.get(source, key) {
        Ok(value) -> Some(value)
        Error(_) -> first_option(rest, key)
      }
  }
}

fn parse_port(source: String) -> Result(Int, ConfigError) {
  case int.parse(source) {
    Ok(value) if value > 0 && value <= 65_535 -> Ok(value)
    _ -> Error(InvalidPort(source))
  }
}

fn parse_bool(key: String, source: String) -> Result(Bool, ConfigError) {
  case source {
    "true" | "1" | "yes" -> Ok(True)
    "false" | "0" | "no" -> Ok(False)
    _ -> Error(InvalidBoolean(key, source))
  }
}

fn parse_positive(key: String, source: String) -> Result(Int, ConfigError) {
  case int.parse(source) {
    Ok(value) if value > 0 -> Ok(value)
    _ -> Error(InvalidPositiveInteger(key, source))
  }
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
