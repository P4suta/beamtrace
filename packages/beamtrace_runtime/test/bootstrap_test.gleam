import beamtrace_runtime/bootstrap
import gleeunit/should

pub fn bootstrap_is_one_time_and_url_token_becomes_http_only_cookie_test() {
  let state =
    bootstrap.new(
      token_hash: "sha256:abc",
      expires_at_ms: 10_000,
      secure_cookie: False,
    )
  let assert Ok(first) =
    bootstrap.exchange(
      state,
      presented_hash: "sha256:abc",
      session_id: "session-1",
      now_ms: 9000,
    )
  first.cookie.http_only |> should.be_true()
  first.cookie.same_site |> should.equal(bootstrap.Strict)
  first.cookie.path |> should.equal("/")
  first.redirect_to |> should.equal("/")

  bootstrap.exchange(
    first.state,
    presented_hash: "sha256:abc",
    session_id: "session-2",
    now_ms: 9001,
  )
  |> should.equal(Error(bootstrap.AlreadyUsed))
}

pub fn bootstrap_expires_test() {
  bootstrap.new("hash", 100, True)
  |> bootstrap.exchange("hash", "session", 101)
  |> should.equal(Error(bootstrap.Expired))
}

pub fn wrong_token_does_not_consume_bootstrap_test() {
  let state = bootstrap.new("right", 100, True)
  bootstrap.exchange(state, "wrong", "session", 1)
  |> should.equal(Error(bootstrap.InvalidToken))

  bootstrap.exchange(state, "right", "session", 2)
  |> should.be_ok()
}
