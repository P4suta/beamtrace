// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/aql
import beamtrace_runtime/cli
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tom

pub type ProjectConfig {
  ProjectConfig(
    path: String,
    defaults: Dict(String, String),
    profiles: List(#(String, Dict(String, String))),
  )
}

pub const template = "# BeamTrace project profiles. Secret values and commands are forbidden.\n"
  <> "[defaults]\n"
  <> "max_roots = 1\n"
  <> "preset = \"generic\"\n"
  <> "\n"
  <> "[profiles.local]\n"
  <> "trigger = \"my_module:my_function/1\"\n"
  <> "out = \"traces/local.beamtrace\"\n"

pub fn prepare(arguments: List(String)) -> Result(List(String), String) {
  use configuration <- result_try(load())
  prepare_with(configuration, arguments)
}

pub fn prepare_with(
  configuration: Option(ProjectConfig),
  arguments: List(String),
) -> Result(List(String), String) {
  case arguments {
    ["capture", ..options] -> prepare_capture(options, configuration)
    ["record", ..options] ->
      prepare_scoped("record", ["record"], options, configuration)
    _ -> Ok(arguments)
  }
}

fn prepare_capture(
  arguments: List(String),
  configuration: Option(ProjectConfig),
) -> Result(List(String), String) {
  let options = case arguments {
    [] -> []
    [first, ..rest] ->
      case string.starts_with(first, "--") {
        True -> arguments
        False -> ["--node", first, ..rest]
      }
  }
  prepare_scoped("capture", ["capture"], options, configuration)
}

pub fn init() -> Result(String, String) {
  init_file(template)
}

pub fn check() -> Result(String, String) {
  case load() {
    Error(error) -> Error(error)
    Ok(None) -> Error("beamtrace.toml was not found")
    Ok(Some(config)) ->
      Ok(
        "valid beamtrace.toml: "
        <> int.to_string(list.length(config.profiles))
        <> " profile(s)",
      )
  }
}

pub fn validate_current() -> Result(Option(ProjectConfig), String) {
  load()
}

/// Return every non-secret cookie file referenced by defaults or profiles.
/// Paths have already been resolved relative to beamtrace.toml.
pub fn cookie_files(config: ProjectConfig) -> List(String) {
  let profile_fields = list.map(config.profiles, fn(profile) { profile.1 })
  collect_cookie_files([config.defaults, ..profile_fields], [])
}

fn collect_cookie_files(
  fields: List(Dict(String, String)),
  accumulator: List(String),
) -> List(String) {
  case fields {
    [] -> list.reverse(accumulator)
    [current, ..rest] ->
      case dict.get(current, "cookie_file") {
        Error(_) -> collect_cookie_files(rest, accumulator)
        Ok(path) ->
          case list.contains(accumulator, path) {
            True -> collect_cookie_files(rest, accumulator)
            False -> collect_cookie_files(rest, [path, ..accumulator])
          }
      }
  }
}

fn prepare_scoped(
  command: String,
  prefix: List(String),
  options: List(String),
  loaded: Option(ProjectConfig),
) -> Result(List(String), String) {
  use selection <- result_try(strip_profile(options, None, []))
  let #(profile_name, explicit) = selection
  case loaded, profile_name {
    None, Some(name) ->
      Error("profile '" <> name <> "' requires a project-local beamtrace.toml")
    None, None -> Ok(list.append(prefix, explicit))
    Some(config), selected -> {
      use profile <- result_try(selected_profile(config, selected))
      let configured =
        list.append(
          fields_to_arguments(command, config.defaults),
          fields_to_arguments(command, profile),
        )
      Ok(prefix |> list.append(configured) |> list.append(explicit))
    }
  }
}

fn strip_profile(
  options: List(String),
  found: Option(String),
  accumulator: List(String),
) -> Result(#(Option(String), List(String)), String) {
  case options {
    [] -> Ok(#(found, list.reverse(accumulator)))
    ["--", ..rest] ->
      Ok(#(found, list.append(list.reverse(accumulator), ["--", ..rest])))
    ["--profile", name, ..rest] if name != "" ->
      case found {
        None -> strip_profile(rest, Some(name), accumulator)
        Some(_) -> Error("--profile may be specified only once")
      }
    ["--profile"] -> Error("--profile requires a name")
    [value, ..rest] -> strip_profile(rest, found, [value, ..accumulator])
  }
}

fn selected_profile(
  config: ProjectConfig,
  selected: Option(String),
) -> Result(Dict(String, String), String) {
  case selected {
    None -> Ok(dict.new())
    Some(name) ->
      case list.key_find(config.profiles, name) {
        Ok(profile) -> Ok(profile)
        Error(_) -> Error("unknown BeamTrace profile '" <> name <> "'")
      }
  }
}

fn fields_to_arguments(
  command: String,
  fields: Dict(String, String),
) -> List(String) {
  let keys = case command {
    "capture" -> [
      "node",
      "trigger",
      "where",
      "out",
      "cookie_file",
      "max_roots",
      "preset",
    ]
    "record" -> [
      "node",
      "trigger",
      "where",
      "out",
      "cookie_file",
      "max_roots",
      "preset",
    ]
    _ -> []
  }
  keys
  |> list.filter_map(fn(key) {
    case dict.get(fields, key) {
      Ok(value) -> Ok(["--" <> string.replace(key, "_", "-"), value])
      Error(_) -> Error(Nil)
    }
  })
  |> list.flatten
}

fn load() -> Result(Option(ProjectConfig), String) {
  case load_file() {
    Error(error) -> Error("could not read beamtrace.toml: " <> error)
    Ok(None) -> Ok(None)
    Ok(Some(file)) -> {
      let #(path, source) = file
      parse(path, source) |> map_result(Some)
    }
  }
}

pub fn parse(path: String, source: String) -> Result(ProjectConfig, String) {
  case tom.parse(source) {
    Error(error) -> Error("invalid TOML: " <> string.inspect(error))
    Ok(document) -> {
      use Nil <- result_try(reject_forbidden(document, []))
      use Nil <- result_try(reject_unknown_top_level(dict.keys(document)))
      use defaults <- result_try(optional_table(document, "defaults"))
      use parsed_defaults <- result_try(parse_fields(path, defaults))
      use profile_table <- result_try(optional_table(document, "profiles"))
      use profiles <- result_try(
        parse_profiles(path, dict.to_list(profile_table), []),
      )
      Ok(ProjectConfig(path, parsed_defaults, profiles))
    }
  }
}

fn parse_profiles(
  path: String,
  entries: List(#(String, tom.Toml)),
  accumulator: List(#(String, Dict(String, String))),
) -> Result(List(#(String, Dict(String, String))), String) {
  case entries {
    [] -> Ok(list.reverse(accumulator))
    [#(name, tom.Table(fields)), ..rest] ->
      case name != "" && string.byte_size(name) <= 128 {
        False -> Error("invalid profile name")
        True -> {
          use parsed <- result_try(parse_fields(path, fields))
          parse_profiles(path, rest, [#(name, parsed), ..accumulator])
        }
      }
    [#(name, _), ..] -> Error("profile '" <> name <> "' must be a table")
  }
}

fn parse_fields(
  path: String,
  fields: Dict(String, tom.Toml),
) -> Result(Dict(String, String), String) {
  parse_field_entries(path, dict.to_list(fields), dict.new())
}

fn parse_field_entries(
  path: String,
  fields: List(#(String, tom.Toml)),
  accumulator: Dict(String, String),
) -> Result(Dict(String, String), String) {
  case fields {
    [] -> Ok(accumulator)
    [#(key, value), ..rest] -> {
      use rendered <- result_try(render_field(path, key, value))
      parse_field_entries(path, rest, dict.insert(accumulator, key, rendered))
    }
  }
}

fn render_field(
  path: String,
  key: String,
  value: tom.Toml,
) -> Result(String, String) {
  case key, value {
    "max_roots", tom.Int(number) if number >= 1 && number <= 1000 ->
      Ok(int.to_string(number))
    "node", tom.String(value) -> bounded_value(key, value)
    "trigger", tom.String(value) -> validate_trigger(value)
    "where", tom.String(value) -> validate_where(value)
    "preset", tom.String(value) -> validate_preset(value)
    "out", tom.String(value) | "cookie_file", tom.String(value) -> {
      use value <- result_try(bounded_value(key, value))
      resolve_path(path, value)
    }
    _, _ -> Error("unsupported or invalid configuration key '" <> key <> "'")
  }
}

fn validate_trigger(value: String) -> Result(String, String) {
  use value <- result_try(bounded_value("trigger", value))
  case cli.parse_mfa(value) {
    Ok(_) -> Ok(value)
    Error(_) -> Error("invalid configuration value for 'trigger'")
  }
}

fn validate_where(value: String) -> Result(String, String) {
  use value <- result_try(bounded_value("where", value))
  case aql.parse(value) {
    Ok(_) -> Ok(value)
    Error(_) -> Error("invalid configuration value for 'where'")
  }
}

fn validate_preset(value: String) -> Result(String, String) {
  use value <- result_try(bounded_value("preset", value))
  case
    list.contains(
      [
        "generic",
        "gleam-actor",
        "wisp-mist",
        "gen-server",
        "phoenix",
        "erlang-supervisor",
      ],
      string.lowercase(value),
    )
  {
    True -> Ok(value)
    False -> Error("invalid configuration value for 'preset'")
  }
}

fn bounded_value(key: String, value: String) -> Result(String, String) {
  case value != "" && string.byte_size(value) <= 4096 {
    True -> Ok(value)
    False -> Error("invalid configuration value for '" <> key <> "'")
  }
}

fn optional_table(
  document: Dict(String, tom.Toml),
  key: String,
) -> Result(Dict(String, tom.Toml), String) {
  case dict.get(document, key) {
    Error(_) -> Ok(dict.new())
    Ok(tom.Table(table)) -> Ok(table)
    Ok(_) -> Error("'" <> key <> "' must be a table")
  }
}

fn reject_unknown_top_level(keys: List(String)) -> Result(Nil, String) {
  case keys {
    [] -> Ok(Nil)
    ["defaults", ..rest] | ["profiles", ..rest] ->
      reject_unknown_top_level(rest)
    [key, ..] ->
      Error("unsupported top-level configuration key '" <> key <> "'")
  }
}

fn reject_forbidden(
  document: Dict(String, tom.Toml),
  prefix: List(String),
) -> Result(Nil, String) {
  reject_entries(dict.to_list(document), prefix)
}

fn reject_entries(
  entries: List(#(String, tom.Toml)),
  prefix: List(String),
) -> Result(Nil, String) {
  case entries {
    [] -> Ok(Nil)
    [#(key, value), ..rest] -> {
      let path = list.reverse([key, ..prefix]) |> string.join(".")
      case forbidden_key(key) {
        True -> Error("secret or command key '" <> path <> "' is forbidden")
        False -> {
          use Nil <- result_try(case value {
            tom.Table(nested) | tom.InlineTable(nested) ->
              reject_forbidden(nested, [key, ..prefix])
            tom.ArrayOfTables(tables) ->
              reject_table_list(tables, [key, ..prefix])
            _ -> Ok(Nil)
          })
          reject_entries(rest, prefix)
        }
      }
    }
  }
}

fn reject_table_list(
  tables: List(Dict(String, tom.Toml)),
  prefix: List(String),
) -> Result(Nil, String) {
  case tables {
    [] -> Ok(Nil)
    [table, ..rest] -> {
      use Nil <- result_try(reject_forbidden(table, prefix))
      reject_table_list(rest, prefix)
    }
  }
}

fn forbidden_key(key: String) -> Bool {
  let key = string.lowercase(key)
  case key == "cookie_file" {
    True -> False
    False ->
      list.any(
        ["command", "cookie", "grant", "oidc", "s3", "secret", "token"],
        fn(part) { string.contains(key, part) },
      )
  }
}

fn result_try(
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

@external(erlang, "beamtrace_project_config_ffi", "load")
fn load_file() -> Result(Option(#(String, String)), String)

@external(erlang, "beamtrace_project_config_ffi", "init")
fn init_file(contents: String) -> Result(String, String)

@external(erlang, "beamtrace_project_config_ffi", "resolve_path")
fn resolve_path(config_path: String, value: String) -> Result(String, String)
