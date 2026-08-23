import beamtrace_runtime
import beamtrace_runtime/internal/version
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn public_version_remains_an_alias_of_the_release_managed_constant_test() {
  beamtrace_runtime.version
  |> should.equal(version.current)
}
