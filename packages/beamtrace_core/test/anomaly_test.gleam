import beamtrace/anomaly
import beamtrace/types
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn mailbox_alert_uses_baseline_and_hysteresis_test() {
  let detector =
    anomaly.new_detector(alpha: 0.25, open_after: 2, close_after: 2)
  let detector = detector |> anomaly.observe(anomaly.Mailbox, 10.0, 1000)
  let detector = detector |> anomaly.observe(anomaly.Mailbox, 11.0, 2000)
  let detector = detector |> anomaly.observe(anomaly.Mailbox, 60.0, 3000)
  detector.active |> should.equal([])

  let detector = detector |> anomaly.observe(anomaly.Mailbox, 70.0, 4000)
  detector.active |> list.length |> should.equal(1)
  let assert [alert] = detector.active
  alert.kind |> should.equal(anomaly.MailboxGrowth)
  let assert types.Inferred(inference) = alert.evidence
  inference.method |> should.equal("ewma_hysteresis_v2")
  inference.reason |> should.equal("EWMA exceeded baseline with hysteresis")
  inference.inputs |> list.length |> should.equal(4)

  let detector = detector |> anomaly.observe(anomaly.Mailbox, 10.0, 5000)
  detector.active |> list.length |> should.equal(1)
  let detector = detector |> anomaly.observe(anomaly.Mailbox, 9.0, 6000)
  detector.active |> should.equal([])
}

pub fn system_signals_are_exact_test() {
  anomaly.from_vm_signal(anomaly.LongGc, 42_000)
  |> should.equal(anomaly.Alert(
    kind: anomaly.LongGarbageCollection,
    summary: "long GC: 42000us",
    evidence: types.Exact,
    opened_at_ns: 0,
  ))
}
