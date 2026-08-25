// SPDX-License-Identifier: Apache-2.0 OR MIT

pub const initial_credits = 8

pub const low_watermark = 4

pub fn initial_window() -> Int {
  initial_credits
}

pub fn refill_batch_count() -> Int {
  initial_credits - low_watermark
}

pub type Refill {
  Refill(granted: Int, available: Int)
}

/// Refill to the shared eight-batch window only after durable acceptance has
/// crossed the low watermark. This is pure so boundary tests need no sleeps.
pub fn after_durable_accept(remaining: Int) -> Refill {
  case remaining <= low_watermark {
    True -> Refill(initial_credits - remaining, initial_credits)
    False -> Refill(0, remaining)
  }
}
