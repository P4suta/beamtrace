// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import gleam/list
import gleam/string
import gleeunit/should

pub fn canonical_v2_golden_documents_are_accepted_test() {
  let assert Ok(manifest) = source("valid/manifest.json")
  manifest |> codec.decode_manifest |> should.be_ok()

  ["valid/event.json", "valid/inferred-event.json"]
  |> list.each(fn(path) { source(path) |> should.be_ok() })
  source("valid/event.json")
  |> result_decode(codec.decode_event)
  |> should.be_ok()
  source("valid/inferred-event.json")
  |> result_decode(codec.decode_event)
  |> should.be_ok()
  source("valid/graph-segment.json")
  |> result_decode(codec.decode_graph_segment)
  |> should.be_ok()
  source("valid/clocks.json")
  |> result_decode(codec.decode_clocks)
  |> should.be_ok()
}

pub fn malformed_v2_golden_documents_are_rejected_test() {
  [
    "invalid/event-unknown-field.json",
    "invalid/event-confidence.json",
    "invalid/event-unsafe-time.json",
    "invalid/event-partial-serial.json",
    "invalid/event-noncanonical.json",
  ]
  |> list.each(fn(path) {
    source(path) |> result_decode(codec.decode_event) |> should.be_error()
  })
  source("invalid/manifest-unknown-version.json")
  |> result_decode(codec.decode_manifest)
  |> should.be_error()
  source("invalid/clocks-invalid-rtt.json")
  |> result_decode(codec.decode_clocks)
  |> should.be_error()
}

fn source(path: String) -> Result(String, String) {
  read_fixture(path) |> result_map(string.trim)
}

fn result_decode(
  source: Result(String, String),
  decoder: fn(String) -> Result(a, b),
) -> Result(a, String) {
  case source {
    Error(error) -> Error(error)
    Ok(value) ->
      case decoder(value) {
        Ok(decoded) -> Ok(decoded)
        Error(_) -> Error("decode_failed")
      }
  }
}

fn result_map(result: Result(a, e), transform: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(transform(value))
    Error(error) -> Error(error)
  }
}

@external(erlang, "beamtrace_format_fixture_ffi", "read")
fn read_fixture(path: String) -> Result(String, String)
