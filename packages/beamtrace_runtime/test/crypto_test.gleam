// SPDX-License-Identifier: Apache-2.0 OR MIT

import beamtrace_runtime/crypto
import gleam/bit_array
import gleam/string
import gleeunit/should

pub fn shared_sha256_and_hmac_vectors_test() {
  crypto.sha256_hex("abc")
  |> should.equal(
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  crypto.hmac_sha256(<<"key":utf8>>, <<
    "The quick brown fox jumps over the lazy dog":utf8,
  >>)
  |> bit_array.base16_encode
  |> string.lowercase
  |> should.equal(
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
  )
}

pub fn shared_random_and_constant_time_contract_test() {
  let first = crypto.random_bytes(32)
  let second = crypto.random_bytes(32)
  bit_array.byte_size(first) |> should.equal(32)
  crypto.constant_time_equal(first, first) |> should.be_true()
  crypto.constant_time_equal(first, second) |> should.be_false()
  crypto.constant_time_equal_string("same", "same") |> should.be_true()
  crypto.constant_time_equal_string("same", "different") |> should.be_false()
  crypto.random_base64url(32) |> string.byte_size |> should.equal(43)
}
