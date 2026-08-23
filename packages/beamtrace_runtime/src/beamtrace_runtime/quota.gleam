// SPDX-License-Identifier: Apache-2.0 OR MIT

pub type Quota {
  Quota(
    max_concurrent_sessions: Int,
    max_events: Int,
    max_bytes: Int,
    max_raw_duration_ms: Int,
  )
}

pub type Request {
  Request(
    active_sessions: Int,
    events: Int,
    bytes: Int,
    raw: Bool,
    duration_ms: Int,
  )
}

pub type QuotaError {
  ConcurrentSessionLimit
  EventLimit
  ByteLimit
  RawDurationLimit
}

pub fn authorize(policy: Quota, request: Request) -> Result(Nil, QuotaError) {
  case
    request.active_sessions >= policy.max_concurrent_sessions,
    request.events > policy.max_events,
    request.bytes > policy.max_bytes,
    request.raw && request.duration_ms > policy.max_raw_duration_ms
  {
    True, _, _, _ -> Error(ConcurrentSessionLimit)
    _, True, _, _ -> Error(EventLimit)
    _, _, True, _ -> Error(ByteLimit)
    _, _, _, True -> Error(RawDurationLimit)
    False, False, False, False -> Ok(Nil)
  }
}
