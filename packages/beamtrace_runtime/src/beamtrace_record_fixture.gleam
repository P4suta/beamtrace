// SPDX-License-Identifier: Apache-2.0 OR MIT

/// Child entrypoint used by record dogfood to exercise `gleam run` and tool
/// shims without adding a shell or losing argument boundaries.
pub fn main() {
  run_fixture()
}

@external(erlang, "beamtrace_demo_fixture", "run_gleam")
fn run_fixture() -> Nil
