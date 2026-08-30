// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// One option in BeamTrace's declarative command specification.
pub type OptionSpec {
  OptionSpec(flag: String, description: String)
}

/// The single source used for root help, command help, examples, defaults and
/// shell completion candidates.
pub type CommandSpec {
  CommandSpec(
    name: String,
    summary: String,
    usage: String,
    defaults: List(String),
    examples: List(String),
    options: List(OptionSpec),
  )
}

pub fn commands() -> List(CommandSpec) {
  [
    CommandSpec(
      "help",
      "Show the command guide or detailed help for one command.",
      "beamtrace help [<command>]",
      [],
      ["beamtrace help capture"],
      [],
    ),
    CommandSpec(
      "attach",
      "Attach an interactive workspace to an existing BEAM node.",
      "beamtrace attach <node> [--web|--tui] [--port PORT] [--no-open]",
      ["Web uses an OS-selected loopback port and opens only on a TTY."],
      ["beamtrace attach app@host --web"],
      common_web_options()
        |> list.append(capture_safety_options()),
    ),
    CommandSpec(
      "capture",
      "Capture one bounded causal operation from an existing node.",
      "beamtrace capture [<node>] --trigger Module:function/arity [options]",
      [
        "Output: beamtrace-YYYYMMDDTHHMMSSZ[-N].beamtrace",
        "Preset: generic; max roots: 1; privacy: metadata",
      ],
      [
        "beamtrace capture app@host --trigger checkout:run/1",
        "beamtrace capture --profile local --trigger checkout:run/1 --out checkout.beamtrace",
      ],
      [
        OptionSpec("--node NODE", "Target node or comma-separated nodes."),
        OptionSpec("--trigger MFA", "Root Module:function/arity to arm."),
        OptionSpec("--where AQL", "Optional root predicate."),
        OptionSpec(
          "--out PATH",
          "Archive path; omitted means a safe generated name.",
        ),
        OptionSpec("--force", "Replace an explicitly named existing archive."),
        OptionSpec("--profile NAME", "Project capture profile."),
        OptionSpec("--max-roots N", "Capture between 1 and 1000 roots."),
        OptionSpec("--preset PRESET", "Capture preset; default generic."),
        OptionSpec("--json", "Emit one versioned JSON result object."),
        ..capture_safety_options()
      ],
    ),
    CommandSpec(
      "record",
      "Launch a Gleam, Mix, Rebar3 or Erlang command and record one MFA.",
      "beamtrace record --trigger Module:function/arity [options] -- <command>",
      [
        "Interactive: Web; non-interactive: no UI",
        "Output: beamtrace-YYYYMMDDTHHMMSSZ[-N].beamtrace",
      ],
      [
        "beamtrace record --trigger app:main/0 -- gleam run",
        "beamtrace record --trigger Elixir.Worker:run/1 --no-ui -- mix run",
      ],
      [
        OptionSpec("--node NODE", "Override the generated target node."),
        OptionSpec("--trigger MFA", "Root Module:function/arity to arm."),
        OptionSpec("--where AQL", "Optional root predicate."),
        OptionSpec(
          "--out PATH",
          "Archive path; omitted means a safe generated name.",
        ),
        OptionSpec("--force", "Replace an explicitly named existing archive."),
        OptionSpec("--web", "Use the Web progress workspace."),
        OptionSpec("--tui", "Use terminal progress UI."),
        OptionSpec("--no-ui", "Disable interactive UI."),
        OptionSpec("--no-open", "Do not launch a browser."),
        OptionSpec("--cookie-file PATH", "Read a distribution cookie file."),
        OptionSpec("--max-roots N", "Capture between 1 and 1000 roots."),
        OptionSpec("--preset PRESET", "Capture preset; default generic."),
        OptionSpec("--json", "Emit one versioned JSON result object."),
      ],
    ),
    CommandSpec(
      "open",
      "Open a trace in the Web workspace or TUI.",
      "beamtrace open <file.beamtrace> [--web|--tui] [--port PORT] [--no-open]",
      ["Web uses an OS-selected loopback port and opens only on a TTY."],
      [
        "beamtrace open checkout.beamtrace",
        "beamtrace open checkout.beamtrace --tui",
      ],
      common_web_options(),
    ),
    CommandSpec(
      "compare",
      "Compare 2 to 20 trace archives.",
      "beamtrace compare <trace.beamtrace> <trace.beamtrace> [more traces] [--web|--tui|--json]",
      ["Two paths with no mode retain the classic terminal comparison."],
      [
        "beamtrace compare before.beamtrace after.beamtrace",
        "beamtrace compare run-1.beamtrace run-2.beamtrace run-3.beamtrace --web",
      ],
      [
        OptionSpec("--web", "Open the multi-run comparison workspace."),
        OptionSpec("--tui", "Open the terminal comparison screen."),
        OptionSpec("--json", "Emit one versioned JSON result object."),
        OptionSpec("--port PORT", "Loopback Web port; default 0."),
        OptionSpec(
          "--no-open",
          "Print the bootstrap URL instead of opening it.",
        ),
      ],
    ),
    CommandSpec(
      "export",
      "Export a trace without changing its evidence semantics.",
      "beamtrace export <file.beamtrace> --format html|jsonl|mermaid|otlp",
      ["Raw values are excluded."],
      ["beamtrace export checkout.beamtrace --format html"],
      [
        OptionSpec("--format FORMAT", "html, jsonl, mermaid, or otlp."),
        OptionSpec(
          "--otlp-anchor-now",
          "Explicitly anchor OTLP to the current time.",
        ),
        OptionSpec("--json", "Emit one versioned JSON result object."),
      ],
    ),
    CommandSpec(
      "validate",
      "Verify container safety, canonical JSON, checksums and the causal graph.",
      "beamtrace validate <file.beamtrace> [--json]",
      [],
      ["beamtrace validate checkout.beamtrace --json"],
      [OptionSpec("--json", "Emit one versioned JSON result object.")],
    ),
    CommandSpec(
      "migrate",
      "Migrate a v1 archive to v2 without modifying the source.",
      "beamtrace migrate <v1.beamtrace> --output <v2.beamtrace>",
      [],
      ["beamtrace migrate old.beamtrace --output migrated.beamtrace"],
      [
        OptionSpec("--output PATH", "Distinct v2 output path."),
        OptionSpec("--json", "Emit one versioned JSON result object."),
      ],
    ),
    CommandSpec(
      "serve",
      "Serve a local or configured Team workspace.",
      "beamtrace serve [--port PORT] [--no-open]",
      ["Local port: 0; Team bind and port come from Team configuration."],
      ["beamtrace serve --no-open"],
      [
        OptionSpec("--port PORT", "Local port; default 0."),
        OptionSpec(
          "--no-open",
          "Print the bootstrap URL instead of opening it.",
        ),
      ],
    ),
    CommandSpec(
      "demo",
      "Record the bundled fixture and show the result.",
      "beamtrace demo [--web|--tui|--no-ui] [--out PATH] [--port PORT]",
      ["Without --out, the temporary archive is removed on exit."],
      ["beamtrace demo", "beamtrace demo --no-ui --out demo.beamtrace"],
      [
        OptionSpec("--web", "Open the Web result workspace."),
        OptionSpec("--tui", "Open the terminal result workspace."),
        OptionSpec("--no-ui", "Record and validate without opening a UI."),
        OptionSpec(
          "--no-open",
          "Print the bootstrap URL instead of opening it.",
        ),
        OptionSpec("--out PATH", "Keep the archive at this path."),
        OptionSpec("--port PORT", "Loopback Web port; default 0."),
        OptionSpec(
          "--json",
          "Emit one versioned JSON result object with --no-ui.",
        ),
      ],
    ),
    CommandSpec(
      "relay",
      "Enroll and run an outbound Team relay.",
      "beamtrace relay <https-hub-url> --enroll TOKEN [capture options]",
      ["The relay never receives a Team-side distribution cookie."],
      ["beamtrace relay https://trace.example --enroll TOKEN"],
      [
        OptionSpec("--enroll TOKEN", "One-time enrollment token."),
        OptionSpec("--node NODE", "Optional producer target."),
        OptionSpec("--trigger MFA", "Producer root MFA."),
        OptionSpec("--raw-grant-file PATH", "Separately authorized raw grant."),
        ..capture_safety_options()
      ],
    ),
    CommandSpec(
      "tui",
      "Open the canonical terminal client.",
      "beamtrace tui [--server URL] [--session-cookie-file PATH]",
      ["Server: http://127.0.0.1:4040"],
      ["beamtrace tui --server https://trace.example"],
      [
        OptionSpec("--server URL", "Local or Team API origin."),
        OptionSpec("--session-cookie-file PATH", "Private OIDC session file."),
      ],
    ),
    CommandSpec(
      "init",
      "Create a safe project-local beamtrace.toml.",
      "beamtrace init [--json]",
      [],
      ["beamtrace init"],
      [OptionSpec("--json", "Emit one versioned JSON result object.")],
    ),
    CommandSpec(
      "config",
      "Validate project defaults and profiles.",
      "beamtrace config check [--json]",
      [],
      ["beamtrace config check"],
      [OptionSpec("--json", "Emit one versioned JSON result object.")],
    ),
    CommandSpec(
      "doctor",
      "Check runtime, assets, distribution and optional tools.",
      "beamtrace doctor [--json]",
      [],
      ["beamtrace doctor --json"],
      [OptionSpec("--json", "Emit one versioned JSON result object.")],
    ),
    CommandSpec(
      "mcp",
      "Run the stdio MCP server.",
      "beamtrace mcp",
      [],
      ["beamtrace mcp"],
      [],
    ),
    CommandSpec(
      "completion",
      "Generate shell completion from this command specification.",
      "beamtrace completion bash|zsh|fish|powershell",
      [],
      ["beamtrace completion zsh > ~/.zfunc/_beamtrace"],
      [],
    ),
    CommandSpec(
      "version",
      "Print the BeamTrace version.",
      "beamtrace version [--json]",
      [],
      ["beamtrace version --json"],
      [OptionSpec("--json", "Emit one versioned JSON result object.")],
    ),
  ]
}

pub fn short_guide() -> String {
  "BeamTrace — causal traces for Gleam, Elixir, and Erlang\n\n"
  <> "Try the 60-second demo:\n  beamtrace demo\n\n"
  <> "Record your app:\n  beamtrace record --trigger Module:function/arity -- <command>\n\n"
  <> "Run 'beamtrace help' for every command."
}

pub fn root_help() -> String {
  let rows =
    commands()
    |> list.map(fn(spec) { "  " <> pad(spec.name, 12) <> spec.summary })
    |> string.join("\n")
  "BeamTrace — BEAM causal workbench\n\n"
  <> "Usage: beamtrace <command> [options]\n\nCommands:\n"
  <> rows
  <> "\n\nRun 'beamtrace help <command>' for options, defaults, and examples.\n"
  <> "Cookie values are accepted only through --cookie-file, BEAMTRACE_COOKIE, or a secure prompt."
}

pub fn command_help(name: String) -> Option(String) {
  case list.find(commands(), fn(spec) { spec.name == name }) {
    Error(_) -> None
    Ok(spec) -> Some(render_spec(spec))
  }
}

pub fn known(name: String) -> Bool {
  commands() |> list.any(fn(spec) { spec.name == name })
}

pub fn names() -> List(String) {
  list.map(commands(), fn(spec) { spec.name })
}

/// Return the nearest command within two single-character edits.
pub fn suggest(input: String) -> Option(String) {
  let left = string.to_graphemes(input)
  case
    list.find(names(), fn(name) {
      within_edits(left, string.to_graphemes(name), 1)
    })
  {
    Ok(name) -> Some(name)
    Error(_) ->
      case
        list.find(names(), fn(name) {
          within_edits(left, string.to_graphemes(name), 2)
        })
      {
        Ok(name) -> Some(name)
        Error(_) -> None
      }
  }
}

pub fn completion(shell: String) -> Option(String) {
  case shell {
    "bash" -> Some(bash_completion())
    "zsh" -> Some(zsh_completion())
    "fish" -> Some(fish_completion())
    "powershell" | "pwsh" -> Some(powershell_completion())
    _ -> None
  }
}

fn common_web_options() -> List(OptionSpec) {
  [
    OptionSpec("--web", "Use the Web workspace."),
    OptionSpec("--tui", "Use the terminal workspace."),
    OptionSpec("--port PORT", "Loopback port; default 0."),
    OptionSpec("--no-open", "Print the bootstrap URL instead of opening it."),
  ]
}

fn capture_safety_options() -> List(OptionSpec) {
  [
    OptionSpec("--cookie-file PATH", "Read a distribution cookie from a file."),
    OptionSpec(
      "--acknowledge-seq-trace-reset",
      "Required outside a TTY for the VM-global seq_trace lease.",
    ),
  ]
}

fn render_spec(spec: CommandSpec) -> String {
  let option_rows = case spec.options {
    [] -> ""
    options -> {
      let rows =
        options
        |> list.map(fn(option) {
          "  " <> pad(option.flag, 34) <> option.description
        })
        |> string.join("\n")
      "\n\nOptions:\n" <> rows
    }
  }
  let defaults = case spec.defaults {
    [] -> ""
    values -> "\n\nDefaults:\n" <> bullet_rows(values)
  }
  let examples = case spec.examples {
    [] -> ""
    values -> "\n\nExamples:\n" <> command_rows(values)
  }
  spec.summary
  <> "\n\nUsage:\n  "
  <> spec.usage
  <> option_rows
  <> defaults
  <> examples
}

fn bullet_rows(values: List(String)) -> String {
  values |> list.map(fn(value) { "  - " <> value }) |> string.join("\n")
}

fn command_rows(values: List(String)) -> String {
  values |> list.map(fn(value) { "  " <> value }) |> string.join("\n")
}

fn pad(value: String, width: Int) -> String {
  let missing = int.max(width - string.length(value), 1)
  value <> repeat_space(missing, "")
}

fn repeat_space(count: Int, accumulator: String) -> String {
  case count <= 0 {
    True -> accumulator
    False -> repeat_space(count - 1, accumulator <> " ")
  }
}

fn within_edits(
  left: List(String),
  right: List(String),
  remaining: Int,
) -> Bool {
  case left, right {
    [], [] -> True
    [], rest -> list.length(rest) <= remaining
    rest, [] -> list.length(rest) <= remaining
    [a, ..left_rest], [b, ..right_rest] if a == b ->
      within_edits(left_rest, right_rest, remaining)
    _, _ if remaining <= 0 -> False
    [_, ..left_rest], [_, ..right_rest] ->
      within_edits(left_rest, right, remaining - 1)
      || within_edits(left, right_rest, remaining - 1)
      || within_edits(left_rest, right_rest, remaining - 1)
  }
}

fn command_words() -> String {
  names() |> string.join(" ")
}

fn bash_completion() -> String {
  "# generated by beamtrace completion bash\n"
  <> "_beamtrace() {\n"
  <> "  local current=${COMP_WORDS[COMP_CWORD]}\n"
  <> "  if [ ${COMP_CWORD} -eq 1 ]; then\n"
  <> "    COMPREPLY=( $(compgen -W '"
  <> command_words()
  <> "' -- \"${current}\") )\n"
  <> "    return\n  fi\n"
  <> "  case ${COMP_WORDS[1]} in\n"
  <> completion_cases(
    "    ",
    "COMPREPLY=( $(compgen -W '",
    "' -- \"${current}\") );;",
  )
  <> "  esac\n}\ncomplete -F _beamtrace beamtrace\n"
}

fn zsh_completion() -> String {
  let command_descriptions =
    commands()
    |> list.map(fn(spec) { "'" <> spec.name <> ":" <> spec.summary <> "'" })
    |> string.join(" ")
  "#compdef beamtrace\n# generated by beamtrace completion zsh\n"
  <> "local -a commands\ncommands=("
  <> command_descriptions
  <> ")\n_arguments '1:command:->command' '*::arg:->args'\n"
  <> "case $state in\n  command) _describe command commands ;;\n  args)\n    case $words[2] in\n"
  <> completion_cases("      ", "_arguments ", ";;")
  <> "    esac\n  ;;\nesac\n"
}

fn fish_completion() -> String {
  let command_rows =
    commands()
    |> list.map(fn(spec) {
      "complete -c beamtrace -n '__fish_use_subcommand' -a '"
      <> spec.name
      <> "' -d '"
      <> spec.summary
      <> "'"
    })
    |> string.join("\n")
  let option_rows =
    commands()
    |> list.flat_map(fn(spec) {
      spec.options
      |> list.map(fn(option) {
        let flag = option_name(option.flag)
        "complete -c beamtrace -n '__fish_seen_subcommand_from "
        <> spec.name
        <> "' -l "
        <> string.drop_start(flag, 2)
        <> " -d '"
        <> option.description
        <> "'"
      })
    })
    |> string.join("\n")
  "# generated by beamtrace completion fish\ncomplete -c beamtrace -f\n"
  <> command_rows
  <> "\n"
  <> option_rows
  <> "\n"
}

fn powershell_completion() -> String {
  let names = names() |> string.join("','")
  "# generated by beamtrace completion powershell\n"
  <> "Register-ArgumentCompleter -Native -CommandName beamtrace -ScriptBlock {\n"
  <> "  param($wordToComplete, $commandAst, $cursorPosition)\n"
  <> "  @('"
  <> names
  <> "') | Where-Object { $_ -like \"$wordToComplete*\" } | ForEach-Object {\n"
  <> "    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)\n"
  <> "  }\n}\n"
}

fn completion_cases(indent: String, prefix: String, suffix: String) -> String {
  commands()
  |> list.map(fn(spec) {
    let options =
      spec.options
      |> list.map(fn(option) { option_name(option.flag) })
      |> string.join(" ")
    indent <> spec.name <> ") " <> prefix <> "'" <> options <> "'" <> suffix
  })
  |> string.join("\n")
  |> fn(value) { value <> "\n" }
}

fn option_name(flag: String) -> String {
  case string.split(flag, on: " ") {
    [name, ..] -> name
    [] -> flag
  }
}
