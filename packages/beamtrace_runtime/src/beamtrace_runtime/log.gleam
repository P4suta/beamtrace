// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/io
import gleam/json
import gleam/list
import gleam/string

pub type Format {
  Human
  Json
}

pub type Level {
  Info
  Error
}

pub type Field {
  Field(name: String, value: String)
}

/// Emit a structured lifecycle record. Sensitive field names are dropped at
/// this boundary so tokens, cookies, payloads and provider credentials cannot
/// accidentally become log data.
pub fn emit(level: Level, event: String, fields: List(Field)) -> Nil {
  render(configured_format(), level, event, fields) |> io.println_error
}

pub fn render(
  format: Format,
  level: Level,
  event: String,
  fields: List(Field),
) -> String {
  let safe = list.filter(fields, field_is_safe)
  case format {
    Human ->
      [
        level_name(level),
        event,
        ..list.map(safe, fn(field) {
          field.name <> "=" <> string.inspect(field.value)
        })
      ]
      |> string.join(" ")
    Json ->
      json.object([
        #("level", json.string(level_name(level))),
        #("event", json.string(event)),
        #(
          "fields",
          safe
            |> list.map(fn(field) { #(field.name, json.string(field.value)) })
            |> json.object,
        ),
      ])
      |> json.to_string
  }
}

fn configured_format() -> Format {
  case log_format() {
    "json" -> Json
    _ -> Human
  }
}

fn level_name(level: Level) -> String {
  case level {
    Info -> "info"
    Error -> "error"
  }
}

fn field_is_safe(field: Field) -> Bool {
  let name = string.lowercase(field.name)
  !list.any(
    [
      "token",
      "cookie",
      "payload",
      "secret",
      "password",
      "authorization",
      "credential",
      "client_secret",
      "raw",
    ],
    fn(forbidden) { string.contains(name, forbidden) },
  )
}

@external(erlang, "beamtrace_log_ffi", "format")
fn log_format() -> String
