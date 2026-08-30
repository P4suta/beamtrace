// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/cli_spec
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should

@external(erlang, "beamtrace_completion_test_ffi", "probe")
fn probe(shell: String, script: String, line: String) -> Result(String, String)

fn candidates(shell: String, line: String) -> Result(List(String), String) {
  let assert Some(script) = cli_spec.completion(shell)
  case probe(shell, script, line) {
    Ok("skipped") -> Ok(["skipped"])
    Ok(output) ->
      Ok(
        output
        |> string.split(on: "\n")
        |> list.map(string.trim)
        |> list.filter(fn(line) { line != "" }),
      )
    Error(reason) -> Error(reason)
  }
}

fn expect(result: Result(List(String), String), wanted: List(String)) {
  let assert Ok(found) = result
  case found {
    ["skipped"] -> Nil
    _ ->
      list.each(wanted, fn(word) {
        case
          list.contains(found, word)
          || list.any(found, string.starts_with(_, word))
        {
          True -> Nil
          False ->
            panic as {
              "missing candidate " <> word <> " in " <> string.join(found, ",")
            }
        }
      })
  }
}

pub fn bash_completion_quotes_option_words_exactly_once_test() {
  let assert Some(bash) = cli_spec.completion("bash")
  bash |> string.contains("''") |> should.be_false()
  bash
  |> string.contains(
    "export) COMPREPLY=( $(compgen -W '--format --otlp-anchor-now --json' -- \"${current}\") );;",
  )
  |> should.be_true()
}

pub fn bash_completes_options_values_and_shells_test() {
  expect(candidates("bash", "beamtrace export trace.beamtrace --f"), [
    "--format",
  ])
  expect(candidates("bash", "beamtrace export trace.beamtrace --format "), [
    "html", "jsonl", "mermaid", "otlp",
  ])
  expect(candidates("bash", "beamtrace completion "), [
    "bash", "zsh", "fish", "powershell",
  ])
  expect(candidates("bash", "beamtrace record --pre"), ["--preset"])
}

pub fn zsh_completion_script_is_syntactically_valid_test() {
  let assert Ok(_) = candidates("zsh", "")
  let assert Some(zsh) = cli_spec.completion("zsh")
  zsh
  |> string.contains(
    "'--format[html, jsonl, mermaid, or otlp.]:format:(html jsonl mermaid otlp)'",
  )
  |> should.be_true()
  zsh |> string.contains("_files -g \"*.beamtrace\"") |> should.be_true()
}

pub fn fish_completes_options_test() {
  expect(candidates("fish", "beamtrace export trace.beamtrace --"), ["--format"])
}

pub fn powershell_completes_options_test() {
  expect(candidates("powershell", "beamtrace export trace.beamtrace --f"), [
    "--format",
  ])
}
