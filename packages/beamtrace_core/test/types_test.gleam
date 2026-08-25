import beamtrace/types
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn inference_is_reproducible_without_confidence_test() {
  types.inferred("logical_actor_v2", "logical actor evidence", [
    types.EvidenceEvent("spawn-1"),
    types.AlgorithmSetting("restart_window_ms", "250"),
  ])
  |> should.equal(
    types.Inferred(
      types.Inference("logical_actor_v2", "logical actor evidence", [
        types.EvidenceEvent("spawn-1"),
        types.AlgorithmSetting("restart_window_ms", "250"),
      ]),
    ),
  )
}

pub fn capture_issues_are_independent_from_observation_end_test() {
  [
    types.CaptureOutcome(
      types.BudgetReached("events"),
      [types.DroppedEvents("one@host", 12)],
      [types.NodeReceipt("one@host", 3, 20, 4096)],
    ),
    types.CaptureOutcome(
      types.QuietPeriod(250),
      [types.MissingNode("down@node")],
      [types.NodeReceipt("one@host", 3, 20, 4096)],
    ),
    types.CaptureOutcome(types.AgentFailure("one@host", "down"), [], []),
  ]
  |> list.all(fn(value) { !types.delivery_verified(value) })
  |> should.be_true()
}

pub fn verified_delivery_requires_receipts_and_no_issues_test() {
  types.CaptureOutcome(types.QuietPeriod(250), [], [
    types.NodeReceipt("one@host", 3, 20, 4096),
  ])
  |> types.delivery_verified
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
