// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/credit_policy
import gleeunit/should

pub fn credit_refill_crosses_the_boundary_without_timing_or_sleep_test() {
  credit_policy.after_durable_accept(5)
  |> should.equal(credit_policy.Refill(0, 5))
  credit_policy.after_durable_accept(4)
  |> should.equal(credit_policy.Refill(4, 8))
  credit_policy.after_durable_accept(0)
  |> should.equal(credit_policy.Refill(8, 8))
}
