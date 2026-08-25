// SPDX-License-Identifier: Apache-2.0 OR MIT

import gleam/bit_array
import gleam/crypto as gleam_crypto
import gleam/string

pub fn sha256(data: BitArray) -> BitArray {
  gleam_crypto.hash(gleam_crypto.Sha256, data)
}

pub fn sha256_hex(value: String) -> String {
  value
  |> bit_array.from_string
  |> sha256
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn sha256_base64url(value: String) -> String {
  value
  |> bit_array.from_string
  |> sha256
  |> bit_array.base64_url_encode(False)
}

pub fn hmac_sha256(key: BitArray, data: BitArray) -> BitArray {
  gleam_crypto.hmac(data, gleam_crypto.Sha256, key)
}

pub fn random_bytes(count: Int) -> BitArray {
  gleam_crypto.strong_random_bytes(count)
}

pub fn random_hex(count: Int) -> String {
  count
  |> random_bytes
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn random_base64url(count: Int) -> String {
  count |> random_bytes |> bit_array.base64_url_encode(False)
}

pub fn constant_time_equal(left: BitArray, right: BitArray) -> Bool {
  gleam_crypto.secure_compare(left, right)
}

pub fn constant_time_equal_string(left: String, right: String) -> Bool {
  constant_time_equal(bit_array.from_string(left), bit_array.from_string(right))
}
