// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/list

pub type CaptureClass {
  MetadataCapture
  RawCapture
}

pub type Policy {
  Policy(metadata_ttl_ms: Int, raw_ttl_ms: Int)
}

pub type RetentionRecord {
  RetentionRecord(
    id: String,
    capture_class: CaptureClass,
    created_at_ms: Int,
    legal_hold: Bool,
  )
}

pub type DeleteReason {
  ExpiredMetadataCapture
  ExpiredRawCapture
}

pub type QuarantineReason {
  FutureTimestamp
}

pub type Decision {
  Keep
  Delete(DeleteReason)
  Quarantine(QuarantineReason)
}

pub type Sweep {
  Sweep(
    keep: List(RetentionRecord),
    delete: List(#(RetentionRecord, DeleteReason)),
    quarantine: List(#(RetentionRecord, QuarantineReason)),
  )
}

pub fn decide(
  policy: Policy,
  record: RetentionRecord,
  now_ms: Int,
) -> Decision {
  case record.created_at_ms > now_ms, record.legal_hold {
    True, _ -> Quarantine(FutureTimestamp)
    False, True -> Keep
    False, False -> decide_expiry(policy, record, now_ms)
  }
}

fn decide_expiry(
  policy: Policy,
  record: RetentionRecord,
  now_ms: Int,
) -> Decision {
  let age_ms = now_ms - record.created_at_ms
  case record.capture_class {
    MetadataCapture ->
      case age_ms >= policy.metadata_ttl_ms {
        True -> Delete(ExpiredMetadataCapture)
        False -> Keep
      }
    RawCapture ->
      case age_ms >= policy.raw_ttl_ms {
        True -> Delete(ExpiredRawCapture)
        False -> Keep
      }
  }
}

pub fn sweep(
  policy: Policy,
  records: List(RetentionRecord),
  now_ms: Int,
) -> Sweep {
  sweep_records(policy, records, now_ms, [], [], [])
}

fn sweep_records(
  policy: Policy,
  records: List(RetentionRecord),
  now_ms: Int,
  keep: List(RetentionRecord),
  delete: List(#(RetentionRecord, DeleteReason)),
  quarantine: List(#(RetentionRecord, QuarantineReason)),
) -> Sweep {
  case records {
    [] ->
      Sweep(list.reverse(keep), list.reverse(delete), list.reverse(quarantine))
    [record, ..rest] ->
      case decide(policy, record, now_ms) {
        Keep ->
          sweep_records(
            policy,
            rest,
            now_ms,
            [record, ..keep],
            delete,
            quarantine,
          )
        Delete(reason) ->
          sweep_records(
            policy,
            rest,
            now_ms,
            keep,
            [#(record, reason), ..delete],
            quarantine,
          )
        Quarantine(reason) ->
          sweep_records(policy, rest, now_ms, keep, delete, [
            #(record, reason),
            ..quarantine
          ])
      }
  }
}
