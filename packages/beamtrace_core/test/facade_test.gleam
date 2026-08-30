import beamtrace
import beamtrace/codec
import beamtrace/dag
import beamtrace/mfa
import beamtrace/types
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn event(id: String) -> types.TraceEvent {
  types.TraceEvent(
    id: id,
    root_id: "root",
    node: "app@host",
    process: types.ProcessIdentity(
      physical: types.ProcessRef("app@host", "<0.1.0>"),
      logical: None,
      evidence: [],
    ),
    local_instant: types.LocalInstant(1, 1),
    kind: types.Stop("done"),
    evidence: types.Exact,
  )
}

pub fn facade_builds_and_reuses_validated_trace_test() {
  let source = event("one")
  let assert Ok(trace) = beamtrace.from_events([source])

  beamtrace.events(trace) |> should.equal([source])
  beamtrace.graph(trace).events |> should.equal([source])
  beamtrace.compare(trace, trace).added |> should.equal(0)
  let _prepared = beamtrace.prepare(trace)
}

pub fn facade_reports_event_number_and_dag_error_test() {
  let invalid =
    types.TraceEvent(..event("bad"), local_instant: types.LocalInstant(-1, 1))
  beamtrace.from_events([event("ok"), invalid])
  |> should.equal(
    Error(beamtrace.EventError(
      2,
      codec.InvalidField(
        "local_instant.offset_ns",
        "must be a non-negative JavaScript-safe relative value",
      ),
    )),
  )

  beamtrace.from_events([event("same"), event("same")])
  |> should.equal(Error(beamtrace.GraphError(dag.DuplicateEventId("same"))))
}

pub fn facade_decodes_canonical_json_and_rejects_noncanonical_json_test() {
  let encoded = codec.encode_event(event("one"))
  let assert Ok(trace) = beamtrace.decode_events([encoded])
  beamtrace.events(trace) |> should.equal([event("one")])

  beamtrace.decode_events([" " <> encoded])
  |> should.equal(Error(beamtrace.EventError(1, codec.NonCanonicalJson)))
}

pub fn mfa_parser_is_typed_and_round_trips_test() {
  let assert Ok(parsed) = mfa.parse("Elixir.Checkout:run/2")
  mfa.to_string(parsed) |> should.equal("Elixir.Checkout:run/2")
  mfa.parse("Checkout:run/256")
  |> should.equal(Error(mfa.ArityOutOfRange(256)))
  mfa.parse("Checkout:run/nope")
  |> should.equal(Error(mfa.InvalidArity("nope")))
  mfa.parse("Checkout:run\u{0}/1")
  |> should.equal(Error(mfa.NulCharacter("function")))
  mfa.parse(string.repeat("m", 256) <> ":run/1")
  |> should.equal(Error(mfa.ComponentTooLong("module", 255)))
}
