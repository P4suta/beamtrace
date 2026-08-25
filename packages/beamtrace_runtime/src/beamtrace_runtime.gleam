// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/cli_lifecycle
import beamtrace_runtime/internal/version as runtime_version

/// The BeamTrace runtime version. This public constant is retained across the
/// v0.2 internal lifecycle split.
pub const version = runtime_version.current

pub fn main() {
  cli_lifecycle.main()
}
