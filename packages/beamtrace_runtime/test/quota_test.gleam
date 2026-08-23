// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/quota
import gleeunit/should

fn policy() {
  quota.Quota(2, 100_000, 64_000_000, 5000)
}

pub fn capture_quota_checks_concurrency_events_bytes_and_raw_duration_test() {
  quota.authorize(policy(), quota.Request(2, 1, 1, False, 1))
  |> should.equal(Error(quota.ConcurrentSessionLimit))
  quota.authorize(policy(), quota.Request(0, 100_001, 1, False, 1))
  |> should.equal(Error(quota.EventLimit))
  quota.authorize(policy(), quota.Request(0, 1, 64_000_001, False, 1))
  |> should.equal(Error(quota.ByteLimit))
  quota.authorize(policy(), quota.Request(0, 1, 1, True, 5001))
  |> should.equal(Error(quota.RawDurationLimit))
  quota.authorize(policy(), quota.Request(0, 100, 1000, True, 4000))
  |> should.equal(Ok(Nil))
}
