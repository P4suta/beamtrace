// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/list
import gleam/option.{type Option, None, Some}

pub const protocol_version = 3

pub type Identity {
  Identity(public_key: BitArray, private_key: BitArray)
}

pub type Mode {
  Exact
  Live
}

pub type Status {
  Connected
  Disconnected(reason: String)
  Truncated(reason: String)
}

pub type Item {
  Event(payload: String)
  Gap(dropped_events: Int)
}

pub type Batch {
  Batch(sequence: Int, items: List(Item))
}

pub type Channel {
  Channel(
    mode: Mode,
    status: Status,
    credits: Int,
    queue: List(String),
    max_queue: Int,
    dropped_live: Int,
    sequence: Int,
    heartbeat_timeout_ms: Int,
    last_heartbeat_ms: Int,
  )
}

@external(erlang, "beamtrace_relay_crypto_ffi", "new_identity")
pub fn new_identity() -> Identity

@external(erlang, "beamtrace_relay_crypto_ffi", "sign")
pub fn sign(identity: Identity, payload: BitArray) -> BitArray

@external(erlang, "beamtrace_relay_crypto_ffi", "verify")
pub fn verify(
  public_key: BitArray,
  payload: BitArray,
  signature: BitArray,
) -> Bool

pub fn new(
  mode: Mode,
  max_queue: Int,
  heartbeat_timeout_ms: Int,
  now_ms: Int,
) -> Channel {
  Channel(
    mode: mode,
    status: Connected,
    credits: 0,
    queue: [],
    max_queue: maximum_one(max_queue),
    dropped_live: 0,
    sequence: 0,
    heartbeat_timeout_ms: maximum_one(heartbeat_timeout_ms),
    last_heartbeat_ms: now_ms,
  )
}

pub fn grant(channel: Channel, credits: Int) -> Channel {
  case channel.status, credits > 0 {
    Connected, True -> Channel(..channel, credits: channel.credits + credits)
    _, _ -> channel
  }
}

pub fn enqueue(channel: Channel, payload: String) -> Channel {
  case
    channel.status,
    list.length(channel.queue) >= channel.max_queue,
    channel.mode
  {
    Connected, False, _ ->
      Channel(..channel, queue: list.append(channel.queue, [payload]))
    Connected, True, Exact ->
      Channel(..channel, status: Truncated("relay_queue_budget"))
    Connected, True, Live ->
      Channel(
        ..channel,
        queue: list.append(drop_first(channel.queue), [payload]),
        dropped_live: channel.dropped_live + 1,
      )
    _, _, _ -> channel
  }
}

pub fn next_batch(
  channel: Channel,
  max_items: Int,
) -> Option(#(Batch, Channel)) {
  case
    channel.status,
    channel.credits > 0,
    channel.queue,
    channel.dropped_live
  {
    Connected, True, [], 0 -> None
    Connected, True, queue, dropped -> {
      let #(events, rest) = take(queue, maximum_one(max_items), [])
      let event_items = list.map(events, Event)
      let items = case dropped > 0 {
        True -> [Gap(dropped), ..event_items]
        False -> event_items
      }
      let sequence = channel.sequence + 1
      Some(#(
        Batch(sequence, items),
        Channel(
          ..channel,
          credits: channel.credits - 1,
          queue: rest,
          dropped_live: 0,
          sequence: sequence,
        ),
      ))
    }
    _, _, _, _ -> None
  }
}

pub fn heartbeat(channel: Channel, now_ms: Int) -> Channel {
  case channel.status {
    Connected -> Channel(..channel, last_heartbeat_ms: now_ms)
    _ -> channel
  }
}

pub fn expire(channel: Channel, now_ms: Int) -> Channel {
  case
    channel.status,
    now_ms - channel.last_heartbeat_ms > channel.heartbeat_timeout_ms
  {
    Connected, True ->
      Channel(..channel, status: Disconnected("heartbeat_timeout"))
    _, _ -> channel
  }
}

fn take(
  items: List(a),
  remaining: Int,
  accumulator: List(a),
) -> #(List(a), List(a)) {
  case items, remaining {
    rest, 0 -> #(list.reverse(accumulator), rest)
    [], _ -> #(list.reverse(accumulator), [])
    [item, ..rest], _ -> take(rest, remaining - 1, [item, ..accumulator])
  }
}

fn drop_first(items: List(a)) -> List(a) {
  case items {
    [] -> []
    [_, ..rest] -> rest
  }
}

fn maximum_one(value: Int) -> Int {
  case value < 1 {
    True -> 1
    False -> value
  }
}
