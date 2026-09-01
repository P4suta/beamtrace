//// Parse and render validated BEAM module/function/arity identifiers.
////
//// Parsing is O(n), accepts exactly `Module:function/arity`, and returns a
//// typed error for empty/oversized/NUL-containing components, non-integer
//// arity, or arity outside 0..255. `mfa.to_string` is the canonical
//// cross-target rendering.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types
import gleam/int
import gleam/string

/// A typed reason why an MFA string could not be parsed.
pub type MfaError {
  InvalidFormat
  EmptyModule
  EmptyFunction
  ComponentTooLong(component: String, maximum_bytes: Int)
  NulCharacter(component: String)
  InvalidArity(value: String)
  ArityOutOfRange(value: Int)
}

/// Parse `Module:function/arity` into a validated BEAM MFA.
///
/// Arity is limited to the BEAM range 0..255. Parsing is linear in the input
/// length and behaves identically on Erlang and JavaScript targets.
pub fn parse(source: String) -> Result(types.Mfa, MfaError) {
  case string.split(source, on: ":") {
    ["", _] -> Error(EmptyModule)
    [module, function_and_arity] ->
      case validate_component(module, "module") {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case string.split(function_and_arity, on: "/") {
            ["", _] -> Error(EmptyFunction)
            [function, arity_source] ->
              case validate_component(function, "function") {
                Error(error) -> Error(error)
                Ok(Nil) ->
                  case int.parse(arity_source) {
                    Error(_) -> Error(InvalidArity(arity_source))
                    Ok(arity) if arity < 0 || arity > 255 ->
                      Error(ArityOutOfRange(arity))
                    Ok(arity) -> Ok(types.Mfa(module, function, arity))
                  }
              }
            _ -> Error(InvalidFormat)
          }
      }
    _ -> Error(InvalidFormat)
  }
}

fn validate_component(
  value: String,
  component: String,
) -> Result(Nil, MfaError) {
  case string.byte_size(value) > 255, string.contains(value, "\u{0}") {
    True, _ -> Error(ComponentTooLong(component, 255))
    _, True -> Error(NulCharacter(component))
    False, False -> Ok(Nil)
  }
}

/// Render an MFA in BeamTrace's canonical `Module:function/arity` form.
pub fn to_string(value: types.Mfa) -> String {
  value.module <> ":" <> value.function <> "/" <> int.to_string(value.arity)
}

/// Render a stable explanation suitable for CLI and library consumers.
pub fn error_message(error: MfaError) -> String {
  case error {
    InvalidFormat -> "expected Module:function/arity"
    EmptyModule -> "module must not be empty"
    EmptyFunction -> "function must not be empty"
    ComponentTooLong(component, maximum) ->
      component
      <> " must be at most "
      <> int.to_string(maximum)
      <> " UTF-8 bytes"
    NulCharacter(component) -> component <> " must not contain a NUL byte"
    InvalidArity(value) -> "arity '" <> value <> "' is not an integer"
    ArityOutOfRange(value) ->
      "arity " <> int.to_string(value) <> " must be between 0 and 255"
  }
}
