// SPDX-License-Identifier: Apache-2.0 OR MIT

import beamtrace_runtime/team_tui
import beamtrace_tui/model
import gleam/string
import gleeunit/should

pub fn team_trace_page_maps_into_the_real_tui_selector_model_test() {
  let source =
    "{\"traces\":[{\"id\":\"session-1\",\"status\":\"complete\",\"node\":\"app@host\",\"mfa\":{\"module\":\"shop\",\"function\":\"checkout\",\"arity\":2},\"privacy\":\"raw\",\"event_count\":42,\"received_at_ms\":1700000000000,\"locked\":true}],\"next_cursor\":null}"
  team_tui.decode_traces(source)
  |> should.equal(
    Ok([
      model.TeamTrace(
        "session-1",
        "complete",
        "app@host",
        "shop:checkout/2",
        "raw",
        42,
        1_700_000_000_000,
        True,
      ),
    ]),
  )
}

pub fn team_trace_page_rejects_unbounded_or_invalid_input_test() {
  team_tui.decode_traces("{}")
  |> should.be_error()

  team_tui.decode_traces(string.repeat("x", 1_048_577))
  |> should.equal(Error("team trace response exceeded 1 MiB"))
}
