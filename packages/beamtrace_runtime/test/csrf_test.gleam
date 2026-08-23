// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/csrf
import gleam/option.{None, Some}
import gleeunit/should

pub fn mutating_request_requires_same_origin_and_double_submit_token_test() {
  csrf.authorize(
    csrf.Post,
    origin: Some("https://hub.example"),
    expected_origin: "https://hub.example",
    session_token: Some("token"),
    header_token: Some("token"),
  )
  |> should.equal(Ok(Nil))

  csrf.authorize(
    csrf.Post,
    Some("https://evil.example"),
    "https://hub.example",
    Some("token"),
    Some("token"),
  )
  |> should.equal(Error(csrf.OriginMismatch))

  csrf.authorize(
    csrf.Delete,
    Some("https://hub.example"),
    "https://hub.example",
    Some("token"),
    None,
  )
  |> should.equal(Error(csrf.MissingToken))
}

pub fn safe_same_origin_get_needs_no_csrf_token_test() {
  csrf.authorize(
    csrf.Get,
    Some("https://hub.example"),
    "https://hub.example",
    None,
    None,
  )
  |> should.equal(Ok(Nil))
}
