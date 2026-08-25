import beamtrace/codec
import beamtrace/dag
import beamtrace/types
import beamtrace_runtime/export
import beamtrace_runtime/storage
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import v2_fixture

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
      v2_fixture.instant(1),
      types.Exit(types.Scalar("string", Some(secret), Some("fingerprint"))),
      types.Exact,
    )
  let archive =
    storage.Archive(
      codec.Manifest(
        2,
        "0.3.0",
        "capture",
        ["node@host"],
        v2_fixture.verified_outcome(),
        types.Raw(types.RawPolicy([], 2, 8)),
      ),
      [event],
      dag.CausalGraph([event], [], []),
      types.empty_calibration(),
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
      v2_fixture.manifest("capture", ["node@host"]),
      [],
      dag.CausalGraph([], [], []),
      types.empty_calibration(),
    )
  export.mermaid(archive)
  |> should.equal("flowchart LR\n  empty[\"No captured events\"]\n")
}

pub fn otlp_export_is_metadata_only_and_has_no_external_dependency_test() {
  let secret = "SENTINEL-otlp-secret"
  let process =
    types.ProcessIdentity(types.ProcessRef("node@host", "<0.1.0>"), None, [])
  let event =
    types.TraceEvent(
      "event",
      "root",
      "node@host",
      process,
      v2_fixture.instant(1),
      types.Exit(types.Scalar("string", Some(secret), None)),
      types.Exact,
    )
  let archive =
    storage.Archive(
      codec.Manifest(
        2,
        "0.3.0",
        "capture",
        ["node@host"],
        v2_fixture.verified_outcome(),
        types.Raw(types.RawPolicy([], 2, 8)),
      ),
      [event],
      dag.CausalGraph([event], [], []),
      types.ClockCalibration(1_700_000_000_000_000_000, [
        types.NodeClock(
          "node@host",
          1000,
          Some(types.ClockSample(1000, 1_700_000_000_000_000_000, 5, 10)),
          Some(types.ClockSample(2000, 1_700_000_000_000_001_000, 5, 10)),
        ),
      ]),
    )

  let assert Ok(json) =
    export.otlp(archive, include_raw: False, anchor_now: False)
  json |> string.contains("resourceSpans") |> should.be_true()
  json |> string.contains("beamtrace.capture_id") |> should.be_true()
  json |> string.contains("capture-calibration") |> should.be_true()
  json
  |> string.contains("\"startTimeUnixNano\":\"1700000000000000001\"")
  |> should.be_true()
  json |> string.contains("beamtrace.local_offset_ns") |> should.be_true()
  json |> string.contains("beamtrace.time.lower_unix_ns") |> should.be_true()
  json |> string.contains(secret) |> should.be_false()
}

pub fn v1_otlp_requires_explicit_synthetic_anchor_test() {
  let event =
    types.TraceEvent(
      "legacy-event",
      "legacy-root",
      "node@host",
      types.ProcessIdentity(types.ProcessRef("node@host", "<0.1.0>"), None, []),
      v2_fixture.instant(0),
      types.Stop("done"),
      types.Exact,
    )
  let archive =
    storage.Archive(
      codec.Manifest(
        1,
        "0.2.0",
        "legacy-capture",
        ["node@host"],
        types.CaptureOutcome(
          types.LegacyUnknown,
          [types.LegacyUnverified("v1")],
          [],
        ),
        types.Metadata,
      ),
      [event],
      dag.CausalGraph([event], [], []),
      types.empty_calibration(),
    )
  export.otlp(archive, include_raw: False, anchor_now: False)
  |> should.equal(Error(
    "v1_clock_information_unavailable; pass --otlp-anchor-now to accept an explicit synthetic anchor",
  ))
  let assert Ok(json) =
    export.otlp(archive, include_raw: False, anchor_now: True)
  json |> string.contains("explicit-legacy-anchor-now") |> should.be_true()
}
