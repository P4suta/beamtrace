// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/s3_blob

pub type Blob {
  Blob(key: String, sha256: String, bytes: Int)
}

pub type Backend {
  Filesystem(root: String)
  S3(config: s3_blob.Config)
}

pub fn filesystem(root: String) -> Backend {
  Filesystem(root)
}

pub fn s3(
  endpoint endpoint: String,
  bucket bucket: String,
  region region: String,
  prefix prefix: String,
) -> Result(Backend, String) {
  let config = s3_blob.Config(endpoint, bucket, region, prefix)
  case s3_blob.valid_config(config) {
    True -> Ok(S3(config))
    False -> Error("invalid_s3_config")
  }
}

pub fn put_with(
  backend: Backend,
  key: String,
  payload: String,
) -> Result(Blob, String) {
  case backend {
    Filesystem(root) -> put(root, key, payload)
    S3(config) ->
      case s3_blob.put(config, key, payload) {
        Ok(#(stored_key, sha256, bytes)) -> Ok(Blob(stored_key, sha256, bytes))
        Error(error) -> Error(error)
      }
  }
}

pub fn read_with(backend: Backend, key: String) -> Result(String, String) {
  case backend {
    Filesystem(root) -> read(root, key)
    S3(config) -> s3_blob.read(config, key)
  }
}

pub fn read_verified_with(
  backend: Backend,
  key: String,
  sha256: String,
  bytes: Int,
) -> Result(String, String) {
  case backend {
    Filesystem(root) -> read_verified(root, key, sha256, bytes)
    S3(config) ->
      case s3_blob.read(config, key) {
        Error(error) -> Error(error)
        Ok(payload) -> verify_payload(payload, sha256, bytes)
      }
  }
}

pub fn delete_with(backend: Backend, key: String) -> Result(Nil, String) {
  case backend {
    Filesystem(root) -> delete(root, key)
    S3(config) -> s3_blob.delete(config, key)
  }
}

@external(erlang, "beamtrace_blob_store_ffi", "verify_payload")
fn verify_payload(
  payload: String,
  sha256: String,
  bytes: Int,
) -> Result(String, String)

@external(erlang, "beamtrace_blob_store_ffi", "put")
pub fn put(root: String, key: String, payload: String) -> Result(Blob, String)

@external(erlang, "beamtrace_blob_store_ffi", "read")
pub fn read(root: String, key: String) -> Result(String, String)

@external(erlang, "beamtrace_blob_store_ffi", "read_verified")
pub fn read_verified(
  root: String,
  key: String,
  sha256: String,
  bytes: Int,
) -> Result(String, String)

@external(erlang, "beamtrace_blob_store_ffi", "delete")
pub fn delete(root: String, key: String) -> Result(Nil, String)
