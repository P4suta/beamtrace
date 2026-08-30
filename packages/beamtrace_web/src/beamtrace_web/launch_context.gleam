// SPDX-License-Identifier: Apache-2.0 OR MIT

/// Read and consume the comparison path list carried by the one-time local
/// bootstrap redirect. The FFI removes it from browser history immediately.
pub fn initial_compare_paths() -> String {
  consume_compare_paths()
}

@external(javascript, "./launch_context_ffi.mjs", "consumeComparePaths")
fn consume_compare_paths() -> String
