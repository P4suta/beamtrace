import beamtrace/types
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn confidence_is_bounded_test() {
  types.inferred("logical actor evidence", 1.7)
  |> should.equal(types.Inferred("logical actor evidence", 1.0))

  types.inferred("weak evidence", -0.2)
  |> should.equal(types.Inferred("weak evidence", 0.0))
}

pub fn incomplete_capture_is_never_reported_complete_test() {
  [
    types.Truncated("event budget"),
    types.Gapped(12),
    types.PartialNode(["down@node"]),
    types.InferredCapture("system tracer occupied"),
  ]
  |> list.all(fn(value) { !types.is_complete(value) })
  |> should.be_true()
}

pub fn metadata_mode_defaults_are_bounded_test() {
  let budget = types.default_budget()
  budget.max_events |> should.equal(100_000)
  budget.max_duration_ms |> should.equal(30_000)
  budget.max_agent_mailbox |> should.equal(10_000)

  types.default_capture_spec(types.Mfa("shop", "checkout", 1)).privacy
  |> should.equal(types.Metadata)
}
