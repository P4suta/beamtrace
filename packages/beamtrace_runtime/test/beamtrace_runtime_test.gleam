import argv
import beamtrace_runtime
import beamtrace_runtime/internal/version
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() {
  let arguments = argv.load().arguments
  case
    list.contains(arguments, "--unit"),
    list.contains(arguments, "--integration")
  {
    True, True -> {
      let unit_ok = run_selected_suite("unit")
      let integration_ok = run_selected_suite("integration")
      let assert True = unit_ok && integration_ok
      Nil
    }
    True, False -> {
      let assert True = run_selected_suite("unit")
      Nil
    }
    _, True -> {
      let assert True = run_selected_suite("integration")
      Nil
    }
    False, False -> gleeunit.main()
  }
}

pub fn public_version_remains_an_alias_of_the_release_managed_constant_test() {
  beamtrace_runtime.version
  |> should.equal(version.current)
}

@external(erlang, "beamtrace_test_suite_ffi", "run")
fn run_selected_suite(suite: String) -> Bool
