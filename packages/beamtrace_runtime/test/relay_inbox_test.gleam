// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/relay_inbox
import gleeunit/should

pub fn exact_inbox_truncates_without_replacing_accepted_frames_test() {
  let store = relay_inbox.new(max_frames: 2, max_bytes: 64)
  relay_inbox.append(
    store,
    "relay-1",
    1,
    relay_inbox.Exact,
    relay_inbox.Metadata,
    "one",
    1000,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    store,
    "relay-1",
    2,
    relay_inbox.Exact,
    relay_inbox.Raw,
    "two",
    1001,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    store,
    "relay-1",
    3,
    relay_inbox.Exact,
    relay_inbox.Unknown,
    "three",
    1002,
  )
  |> should.equal(Ok(relay_inbox.Truncated("hub_inbox_budget")))

  relay_inbox.snapshot(store, "relay-1")
  |> should.equal([
    relay_inbox.Payload(1, relay_inbox.Metadata, "one", 1000),
    relay_inbox.Payload(2, relay_inbox.Raw, "two", 1001),
  ])
  relay_inbox.close(store)
}

pub fn live_inbox_drops_oldest_and_surfaces_an_explicit_gap_test() {
  let store = relay_inbox.new(max_frames: 2, max_bytes: 64)
  relay_inbox.append(
    store,
    "relay-live",
    1,
    relay_inbox.Live,
    relay_inbox.Metadata,
    "one",
    1000,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    store,
    "relay-live",
    2,
    relay_inbox.Live,
    relay_inbox.Raw,
    "two",
    1001,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    store,
    "relay-live",
    3,
    relay_inbox.Live,
    relay_inbox.Unknown,
    "three",
    1002,
  )
  |> should.equal(Ok(relay_inbox.Accepted))

  relay_inbox.snapshot(store, "relay-live")
  |> should.equal([
    relay_inbox.Gap(1, "hub_inbox_budget", 1002),
    relay_inbox.Payload(2, relay_inbox.Raw, "two", 1001),
    relay_inbox.Payload(3, relay_inbox.Unknown, "three", 1002),
  ])
  relay_inbox.close(store)
}

pub fn inbox_rejects_invalid_identity_sequence_and_oversized_single_frame_test() {
  let store = relay_inbox.new(max_frames: 2, max_bytes: 4)
  relay_inbox.append(
    store,
    "",
    1,
    relay_inbox.Exact,
    relay_inbox.Metadata,
    "one",
    1000,
  )
  |> should.equal(Error("invalid_frame"))
  relay_inbox.append(
    store,
    "relay-1",
    0,
    relay_inbox.Exact,
    relay_inbox.Metadata,
    "one",
    1000,
  )
  |> should.equal(Error("invalid_frame"))
  relay_inbox.append(
    store,
    "relay-1",
    1,
    relay_inbox.Exact,
    relay_inbox.Metadata,
    "12345",
    1000,
  )
  |> should.equal(Error("frame_too_large"))
  relay_inbox.close(store)
}

pub fn inbox_window_is_ordered_bounded_and_reports_the_total_test() {
  let store = relay_inbox.new(max_frames: 4, max_bytes: 128)
  relay_inbox.append(
    store,
    "relay-page",
    1,
    relay_inbox.Exact,
    relay_inbox.Metadata,
    "one",
    1000,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    store,
    "relay-page",
    2,
    relay_inbox.Exact,
    relay_inbox.Raw,
    "two",
    1001,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    store,
    "relay-page",
    3,
    relay_inbox.Exact,
    relay_inbox.Unknown,
    "three",
    1002,
  )
  |> should.equal(Ok(relay_inbox.Accepted))

  relay_inbox.window(store, "relay-page", start: 1, limit: 1)
  |> should.equal(
    Ok(relay_inbox.Window(
      entries: [relay_inbox.Payload(2, relay_inbox.Raw, "two", 1001)],
      total: 3,
      start: 1,
      limit: 1,
    )),
  )
  relay_inbox.window(store, "relay-page", start: -1, limit: 1)
  |> should.equal(Error("invalid_window"))
  relay_inbox.window(store, "relay-page", start: 0, limit: 1001)
  |> should.equal(Error("invalid_window"))
  relay_inbox.close(store)
}

pub fn authorized_window_releases_payloads_only_after_raw_approval_test() {
  let store = relay_inbox.new(max_frames: 4, max_bytes: 128)
  relay_inbox.append(
    store,
    "relay-authorized-page",
    1,
    relay_inbox.Exact,
    relay_inbox.Metadata,
    "metadata-payload",
    1000,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    store,
    "relay-authorized-page",
    2,
    relay_inbox.Exact,
    relay_inbox.Raw,
    "raw-secret",
    1001,
  )
  |> should.equal(Ok(relay_inbox.Accepted))
  relay_inbox.append(
    store,
    "relay-authorized-page",
    3,
    relay_inbox.Exact,
    relay_inbox.Unknown,
    "legacy-secret",
    1002,
  )
  |> should.equal(Ok(relay_inbox.Accepted))

  relay_inbox.authorized_window(
    store,
    "relay-authorized-page",
    start: 0,
    limit: 1,
    authorize_raw: fn() { False },
  )
  |> should.equal(
    Ok(relay_inbox.Window(
      entries: [
        relay_inbox.Payload(1, relay_inbox.Metadata, "metadata-payload", 1000),
      ],
      total: 3,
      start: 0,
      limit: 1,
    )),
  )
  relay_inbox.authorized_window(
    store,
    "relay-authorized-page",
    start: 1,
    limit: 1,
    authorize_raw: fn() { False },
  )
  |> should.equal(Error("raw_trace_forbidden"))
  relay_inbox.authorized_window(
    store,
    "relay-authorized-page",
    start: 2,
    limit: 1,
    authorize_raw: fn() { False },
  )
  |> should.equal(Error("raw_trace_forbidden"))
  relay_inbox.authorized_window(
    store,
    "relay-authorized-page",
    start: 1,
    limit: 2,
    authorize_raw: fn() { True },
  )
  |> should.equal(
    Ok(relay_inbox.Window(
      entries: [
        relay_inbox.Payload(2, relay_inbox.Raw, "raw-secret", 1001),
        relay_inbox.Payload(3, relay_inbox.Unknown, "legacy-secret", 1002),
      ],
      total: 3,
      start: 1,
      limit: 2,
    )),
  )
  relay_inbox.close(store)
}
