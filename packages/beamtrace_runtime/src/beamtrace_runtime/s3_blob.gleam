// SPDX-License-Identifier: Apache-2.0 OR MIT

pub type Config {
  Config(endpoint: String, bucket: String, region: String, prefix: String)
}

@external(erlang, "beamtrace_s3_blob_ffi", "valid_config")
pub fn valid_config(config: Config) -> Bool

@external(erlang, "beamtrace_s3_blob_ffi", "put")
pub fn put(
  config: Config,
  key: String,
  payload: String,
) -> Result(#(String, String, Int), String)

@external(erlang, "beamtrace_s3_blob_ffi", "read")
pub fn read(config: Config, key: String) -> Result(String, String)

@external(erlang, "beamtrace_s3_blob_ffi", "delete")
pub fn delete(config: Config, key: String) -> Result(Nil, String)

@external(erlang, "beamtrace_s3_blob_ffi", "authorization_for_test")
pub fn authorization_for_test(
  method method: String,
  canonical_uri canonical_uri: String,
  host host: String,
  region region: String,
  access_key access_key: String,
  secret_key secret_key: String,
  amz_date amz_date: String,
  additional_headers additional_headers: List(#(String, String)),
  payload payload: String,
) -> String
