// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_web/page_loader
import gleeunit/should

pub fn search_query_is_url_encoded_at_the_fetch_boundary_test() {
  page_loader.url(10, 25, "actor&kind / restart")
  |> should.equal(
    "/api/v1/sessions/current/events?start=10&limit=25&q=actor%26kind+%2F+restart",
  )
}

pub fn empty_search_does_not_emit_an_empty_q_parameter_test() {
  page_loader.url(0, 200, "   ")
  |> should.equal("/api/v1/sessions/current/events?start=0&limit=200")
}
