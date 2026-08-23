// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_gleam_fixture as fixture
import gleam/erlang/process
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn call_chain_and_supervisor_restart_test() {
  let assert Ok(runtime) = fixture.start()
  fixture.operation(runtime, 21) |> should.equal(42)
  fixture.bump(runtime)
  fixture.crash(runtime)
  process.sleep(100)
  fixture.operation(runtime, 5) |> should.equal(10)
}
