// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/relay_channel
import gleam/bit_array
import gleam/option.{None, Some}
import gleeunit/should

pub fn relay_identity_signatures_are_ed25519_and_tamper_evident_test() {
  let identity = relay_channel.new_identity()
  bit_array.byte_size(identity.public_key) |> should.equal(32)
  let signature = relay_channel.sign(identity, <<"relay hello":utf8>>)
  bit_array.byte_size(signature) |> should.equal(64)
  relay_channel.verify(identity.public_key, <<"relay hello":utf8>>, signature)
  |> should.be_true()
  relay_channel.verify(identity.public_key, <<"tampered":utf8>>, signature)
  |> should.be_false()
}

pub fn exact_channel_truncates_immediately_at_queue_budget_test() {
  let channel = relay_channel.new(relay_channel.Exact, 2, 1000, 0)
  let channel =
    channel |> relay_channel.enqueue("one") |> relay_channel.enqueue("two")
  let channel = channel |> relay_channel.enqueue("three")

  channel.status |> should.equal(relay_channel.Truncated("relay_queue_budget"))
  channel.queue |> should.equal(["one", "two"])
  relay_channel.next_batch(channel, 10) |> should.equal(None)
}

pub fn live_channel_drops_oldest_and_emits_gap_only_with_credit_test() {
  let channel = relay_channel.new(relay_channel.Live, 2, 1000, 0)
  let channel =
    channel
    |> relay_channel.enqueue("one")
    |> relay_channel.enqueue("two")
    |> relay_channel.enqueue("three")

  relay_channel.next_batch(channel, 10) |> should.equal(None)
  let channel = relay_channel.grant(channel, 1)
  let assert Some(#(batch, drained)) = relay_channel.next_batch(channel, 10)
  batch.items
  |> should.equal([
    relay_channel.Gap(1),
    relay_channel.Event("two"),
    relay_channel.Event("three"),
  ])
  drained.queue |> should.equal([])
  drained.credits |> should.equal(0)
}

pub fn heartbeat_timeout_closes_channel_test() {
  let channel = relay_channel.new(relay_channel.Exact, 10, 100, 1000)
  relay_channel.expire(channel, 1101).status
  |> should.equal(relay_channel.Disconnected("heartbeat_timeout"))
  relay_channel.expire(channel, 1100).status
  |> should.equal(relay_channel.Connected)
}
