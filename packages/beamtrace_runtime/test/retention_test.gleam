// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/retention
import gleeunit/should

const hour_ms = 3_600_000

const day_ms = 86_400_000

fn policy() {
  retention.Policy(metadata_ttl_ms: 30 * day_ms, raw_ttl_ms: 6 * hour_ms)
}

pub fn retention_uses_shorter_raw_capture_ttl_test() {
  let metadata =
    retention.RetentionRecord("metadata", retention.MetadataCapture, 0, False)
  let raw = retention.RetentionRecord("raw", retention.RawCapture, 0, False)

  retention.decide(policy(), metadata, 7 * hour_ms)
  |> should.equal(retention.Keep)
  retention.decide(policy(), raw, 7 * hour_ms)
  |> should.equal(retention.Delete(retention.ExpiredRawCapture))
}

pub fn legal_hold_prevents_deletion_and_boundary_is_expired_test() {
  let held = retention.RetentionRecord("held", retention.RawCapture, 0, True)
  let ordinary =
    retention.RetentionRecord("ordinary", retention.MetadataCapture, 0, False)

  retention.decide(policy(), held, 365 * day_ms)
  |> should.equal(retention.Keep)
  retention.decide(policy(), ordinary, 30 * day_ms)
  |> should.equal(retention.Delete(retention.ExpiredMetadataCapture))
}

pub fn future_timestamp_is_quarantined_instead_of_deleted_test() {
  let future =
    retention.RetentionRecord(
      "future",
      retention.MetadataCapture,
      10_001,
      False,
    )
  retention.decide(policy(), future, 10_000)
  |> should.equal(retention.Quarantine(retention.FutureTimestamp))
}

pub fn sweep_partitions_deletions_without_losing_kept_records_test() {
  let fresh =
    retention.RetentionRecord(
      "fresh",
      retention.MetadataCapture,
      29 * day_ms,
      False,
    )
  let expired =
    retention.RetentionRecord("expired", retention.RawCapture, 0, False)
  let held = retention.RetentionRecord("held", retention.RawCapture, 0, True)
  let records = [fresh, expired, held]
  let result = retention.sweep(policy(), records, 30 * day_ms)
  result.keep |> should.equal([fresh, held])
  result.delete |> should.equal([#(expired, retention.ExpiredRawCapture)])
  result.quarantine |> should.equal([])
}
