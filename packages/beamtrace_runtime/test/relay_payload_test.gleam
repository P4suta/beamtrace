// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/codec
import beamtrace/types
import beamtrace_runtime/relay_payload
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

const sentinel = "SENTINEL-secret-never-cross-relay"

fn event(term: types.TermView) -> types.TraceEvent {
  types.TraceEvent(
    id: "event-1",
    root_id: "root-1",
    node: "fixture@host",
    process: types.ProcessIdentity(
      physical: types.ProcessRef("fixture@host", "<0.1.0>"),
      logical: None,
      evidence: [],
    ),
    local_instant: types.LocalInstant(100, 1),
    kind: types.Exit(term),
    evidence: types.Exact,
  )
}

fn batch(event_json: String, privacy: String, extra: String) -> String {
  "{\"type\":\"batch\",\"mode\":\"exact\",\"privacy\":\""
  <> privacy
  <> "\",\"items\":["
  <> event_json
  <> "]"
  <> extra
  <> "}"
}

pub fn metadata_batch_is_validated_counted_and_canonicalized_test() {
  let fingerprint = string.repeat("a", 64)
  let source =
    batch(
      codec.encode_event(event(types.Scalar("string", None, Some(fingerprint)))),
      "metadata",
      "",
    )
  let assert Ok(decoded) = relay_payload.decode(source)
  decoded.mode |> should.equal("exact")
  decoded.event_count |> should.equal(1)
  decoded.canonical |> string.contains("\"event_schema\":2") |> should.be_true()
  decoded.canonical |> string.contains(fingerprint) |> should.be_true()
  decoded.canonical |> string.contains(sentinel) |> should.be_false()
  relay_payload.decode(decoded.canonical) |> should.equal(Ok(decoded))
}

pub fn metadata_batch_rejects_display_values_and_unhashed_fingerprints_test() {
  batch(
    codec.encode_event(
      event(types.Scalar("string", Some(sentinel), Some(string.repeat("a", 64)))),
    ),
    "metadata",
    "",
  )
  |> relay_payload.decode
  |> should.equal(Error("metadata_value_forbidden"))

  batch(
    codec.encode_event(event(types.BinaryMetadata(32, None, Some(sentinel)))),
    "metadata",
    "",
  )
  |> relay_payload.decode
  |> should.equal(Error("invalid_metadata_fingerprint"))
}

pub fn relay_rejects_raw_unknown_and_oversized_batch_shapes_test() {
  let safe = codec.encode_event(event(types.Hidden))
  batch(safe, "raw", "")
  |> relay_payload.decode
  |> should.equal(Error("raw_capture_not_authorized"))
  batch(safe, "metadata", ",\"secret\":\"" <> sentinel <> "\"")
  |> relay_payload.decode
  |> should.equal(Error("invalid_payload"))

  let items = string.repeat(safe <> ",", 128) <> safe
  batch(items, "metadata", "")
  |> relay_payload.decode
  |> should.equal(Error("batch_event_limit"))
}

pub fn authorized_raw_batch_is_strictly_validated_and_token_is_not_canonicalized_test() {
  let grant = string.repeat("A", 43)
  let policy = types.RawPolicy(["password", "token"], 2, 64)
  let fingerprint = string.repeat("c", 64)
  let raw_event =
    event(
      types.MapView(2, [
        #(types.Atom("token"), types.Redacted("key policy")),
        #(
          types.Atom("answer"),
          types.Scalar("integer", Some("42"), Some(fingerprint)),
        ),
      ]),
    )
  let assert Ok(source) =
    relay_payload.encode_raw("exact", grant, policy, [raw_event])
  source |> string.contains(grant) |> should.be_true()
  relay_payload.decode(source)
  |> should.equal(Error("raw_capture_not_authorized"))

  let assert Ok(decoded) = relay_payload.decode_for_ingest(source)
  let assert relay_payload.RawBatch(received_grant, received_policy) =
    decoded.privacy
  received_grant |> should.equal(grant)
  received_policy |> should.equal(policy)
  decoded.canonical |> string.contains(grant) |> should.be_false()
  decoded.canonical
  |> string.contains("\"privacy\":\"raw\"")
  |> should.be_true()
}

pub fn authorized_raw_batch_rejects_redaction_and_depth_policy_violations_test() {
  let grant = string.repeat("A", 43)
  let fingerprint = string.repeat("d", 64)
  let leaked =
    event(
      types.MapView(1, [
        #(
          types.Atom("password"),
          types.Scalar("string", Some(sentinel), Some(fingerprint)),
        ),
      ]),
    )
  relay_payload.encode_raw(
    "exact",
    grant,
    types.RawPolicy(["password"], 2, 64),
    [leaked],
  )
  |> should.equal(Error("raw_redaction_required"))

  let too_deep = event(types.Tuple([types.Tuple([types.Atom("visible")])]))
  relay_payload.encode_raw(
    "exact",
    grant,
    types.RawPolicy(["password"], 1, 64),
    [too_deep],
  )
  |> should.equal(Error("raw_depth_exceeded"))
}
