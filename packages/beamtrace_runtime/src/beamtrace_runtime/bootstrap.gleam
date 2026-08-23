pub type SameSite {
  Strict
  Lax
}

pub type Cookie {
  Cookie(
    value: String,
    http_only: Bool,
    secure: Bool,
    same_site: SameSite,
    path: String,
    max_age_seconds: Int,
  )
}

pub type Bootstrap {
  Bootstrap(
    token_hash: String,
    expires_at_ms: Int,
    used: Bool,
    secure_cookie: Bool,
  )
}

pub type Exchange {
  Exchange(state: Bootstrap, cookie: Cookie, redirect_to: String)
}

pub type ExchangeError {
  AlreadyUsed
  Expired
  InvalidToken
}

pub fn new(
  token_hash token_hash: String,
  expires_at_ms expires_at_ms: Int,
  secure_cookie secure_cookie: Bool,
) -> Bootstrap {
  Bootstrap(token_hash, expires_at_ms, False, secure_cookie)
}

/// Exchanges a hash of the URL token for a session cookie exactly once. The
/// route must redirect to `/`, which removes the bootstrap token from browser
/// history and subsequent requests.
pub fn exchange(
  state: Bootstrap,
  presented_hash presented_hash: String,
  session_id session_id: String,
  now_ms now_ms: Int,
) -> Result(Exchange, ExchangeError) {
  case
    state.used,
    now_ms > state.expires_at_ms,
    presented_hash == state.token_hash
  {
    True, _, _ -> Error(AlreadyUsed)
    _, True, _ -> Error(Expired)
    _, _, False -> Error(InvalidToken)
    False, False, True ->
      Ok(Exchange(
        state: Bootstrap(..state, used: True),
        cookie: Cookie(
          value: session_id,
          http_only: True,
          secure: state.secure_cookie,
          same_site: Strict,
          path: "/",
          max_age_seconds: 8 * 60 * 60,
        ),
        redirect_to: "/",
      ))
  }
}
