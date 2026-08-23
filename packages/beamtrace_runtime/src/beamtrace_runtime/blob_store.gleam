// SPDX-License-Identifier: Apache-2.0 OR MIT

pub type Blob {
  Blob(key: String, sha256: String, bytes: Int)
}

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
