// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/enrollment_store
import gleam/bit_array
import gleeunit/should

fn public_key() {
  bit_array.base16_decode(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  |> should.be_ok()
}

pub fn issued_code_is_single_use_and_registers_only_the_public_key_test() {
  let #(store, code) = enrollment_store.new_at(1000, 100)
  let assert Ok(relay) =
    enrollment_store.consume(store, code, public_key(), 1050)
  relay.algorithm |> should.equal("Ed25519")
  relay.public_key |> should.equal(public_key())
  bit_array.byte_size(relay.public_key) |> should.equal(32)

  enrollment_store.consume(store, code, public_key(), 1051)
  |> should.equal(Error("already_used"))
  enrollment_store.close(store)
}

pub fn expired_code_cannot_be_revived_test() {
  let #(store, code) = enrollment_store.new_at(1000, 10)
  enrollment_store.consume(store, code, public_key(), 1011)
  |> should.equal(Error("expired"))
  enrollment_store.consume(store, code, public_key(), 1005)
  |> should.equal(Error("expired"))
  enrollment_store.close(store)
}
