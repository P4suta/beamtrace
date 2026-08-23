// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/option.{type Option, None, Some}

pub type Method {
  Get
  Head
  Post
  Put
  Patch
  Delete
}

pub type AuthorizationError {
  OriginMismatch
  MissingToken
  TokenMismatch
}

pub fn authorize(
  method: Method,
  origin origin: Option(String),
  expected_origin expected_origin: String,
  session_token session_token: Option(String),
  header_token header_token: Option(String),
) -> Result(Nil, AuthorizationError) {
  case origin {
    Some(value) if value == expected_origin ->
      authorize_token(method, session_token, header_token)
    None | Some(_) -> Error(OriginMismatch)
  }
}

fn authorize_token(
  method: Method,
  session_token: Option(String),
  header_token: Option(String),
) -> Result(Nil, AuthorizationError) {
  case method {
    Get | Head -> Ok(Nil)
    Post | Put | Patch | Delete ->
      case session_token, header_token {
        None, _ | _, None -> Error(MissingToken)
        Some(session), Some(header) ->
          case session == header {
            True -> Ok(Nil)
            False -> Error(TokenMismatch)
          }
      }
  }
}
