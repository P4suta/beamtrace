import beamtrace/codec
import beamtrace/types
import beamtrace_runtime/export
import beamtrace_runtime/storage
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn html_export_is_self_contained_and_drops_raw_display_test() {
  let secret = "SENTINEL-raw-secret"
  let process =
    types.ProcessIdentity(types.ProcessRef("node@host", "<0.1.0>"), None, [])
  let event =
    types.TraceEvent(
      "event",
      "root",
      "node@host",
      process,
      1,
      types.Exit(types.Scalar("string", Some(secret), Some("fingerprint"))),
      types.Exact,
    )
  let archive =
    storage.Archive(
      codec.Manifest(
        1,
        "0.1.0",
        "capture",
        ["node@host"],
        types.Complete,
        types.Raw(types.RawPolicy([], 2, 8)),
        [],
      ),
      [event],
    )

  let html = export.html(archive, include_raw: False)
  html |> string.contains(secret) |> should.be_false()
  html |> string.contains("https://") |> should.be_false()
  html
  |> string.contains(
    "<script type=\"application/json\" id=\"beamtrace-trace\">",
  )
  |> should.be_true()
  html |> string.contains("Content-Security-Policy") |> should.be_true()
}

pub fn mermaid_export_uses_logical_event_ids_test() {
  let archive =
    storage.Archive(
      codec.Manifest(
        1,
        "0.1.0",
        "capture",
        [],
        types.Complete,
        types.Metadata,
        [],
      ),
      [],
    )
  export.mermaid(archive)
  |> should.equal("flowchart LR\n  empty[\"No captured events\"]\n")
}

pub fn otlp_export_is_metadata_only_and_has_no_external_dependency_test() {
  let secret = "SENTINEL-otlp-secret"
  let process =
    types.ProcessIdentity(types.ProcessRef("node@host", "<0.1.0>"), None, [])
  let archive =
    storage.Archive(
      codec.Manifest(
        1,
        "0.1.0",
        "capture",
        ["node@host"],
        types.Complete,
        types.Raw(types.RawPolicy([], 2, 8)),
        [],
      ),
      [
        types.TraceEvent(
          "event",
          "root",
          "node@host",
          process,
          1,
          types.Exit(types.Scalar("string", Some(secret), None)),
          types.Exact,
        ),
      ],
    )

  let json = export.otlp(archive, include_raw: False)
  json |> string.contains("resourceSpans") |> should.be_true()
  json |> string.contains("beamtrace.capture_id") |> should.be_true()
  json |> string.contains(secret) |> should.be_false()
}
