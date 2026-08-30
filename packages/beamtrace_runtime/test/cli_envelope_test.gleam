// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/cli
import beamtrace_runtime/cli_errors
import beamtrace_runtime/cli_spec
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "beamtrace_test_files_ffi", "read")
fn read_file(path: String) -> Result(String, String)

fn schema() -> String {
  let assert Ok(source) =
    read_file("../../schemas/beamtrace-cli-v1/envelope.schema.json")
  source
}

fn string_enum(path: List(String)) -> List(String) {
  let assert Ok(values) =
    json.parse(schema(), decode.at(path, decode.list(decode.string)))
  values
}

pub fn envelope_schema_command_set_matches_the_specification_test() {
  string_enum(["properties", "command", "enum"])
  |> list.sort(string.compare)
  |> should.equal(list.sort(
    list.append(cli_spec.names(), ["config check", "unknown"]),
    string.compare,
  ))
}

pub fn envelope_schema_lists_every_catalogue_code_test() {
  let assert Ok(alternatives) =
    json.parse(
      schema(),
      decode.at(["properties", "error", "oneOf"], decode.list(decode.dynamic)),
    )
  alternatives
  |> list.flat_map(fn(alternative) {
    case
      decode.run(
        alternative,
        decode.at(["properties", "code", "enum"], decode.list(decode.string)),
      )
    {
      Ok(codes) -> codes
      Error(_) -> []
    }
  })
  |> list.sort(string.compare)
  |> should.equal(cli_errors.codes())
}

pub fn envelope_schema_exit_codes_match_the_enum_test() {
  let assert Ok(exits) =
    json.parse(
      schema(),
      decode.at(["properties", "exit_code", "enum"], decode.list(decode.int)),
    )
  exits
  |> should.equal(list.map(cli_errors.all_exit_codes(), cli_errors.exit_to_int))
  let assert Ok(required) =
    json.parse(schema(), decode.at(["required"], decode.list(decode.string)))
  required
  |> should.equal([
    "schema_version", "command", "ok", "exit_code", "artifact", "outcome",
    "error",
  ])
}

pub fn parse_error_command_name_is_closed_test() {
  cli.invoked_command(["comprae"]) |> should.equal("unknown")
  cli.invoked_command(["config", "check", "--json"]) |> should.equal("config")
  cli.invoked_command(["--json", "validate", "x"]) |> should.equal("validate")
}

pub fn cli_reference_documents_every_error_and_exit_code_test() {
  let assert Ok(reference) = read_file("../../docs/cli-reference.md")
  list.each(cli_errors.all(), fn(error) {
    case
      string.contains(reference, "`" <> cli_errors.human_label(error) <> "`")
    {
      True -> Nil
      False ->
        panic as { "cli-reference.md lacks " <> cli_errors.human_label(error) }
    }
  })
  list.each(cli_spec.names(), fn(name) {
    case string.contains(reference, "`" <> name <> "`") {
      True -> Nil
      False -> panic as { "cli-reference.md lacks command " <> name }
    }
  })
  reference |> string.contains("130") |> should.be_true()
  reference |> string.contains("143") |> should.be_true()
}
