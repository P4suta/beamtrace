//// Reject an AQL field typo with a caret report and a suggestion, then
//// split a valid query into the agent-safe predicate and relay residual.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/aql
import beamtrace/types
import gleam/io
import gleam/option.{None, Some}

pub fn main() {
  let typo = "message.tga == \"charge\" and arg.0.type == tuple"
  let assert Error(error) = aql.parse_for(typo, fields: aql.event_fields())
  io.println(aql.error_report(source: typo, error: error))

  let assert Ok(query) =
    aql.parse_for(
      "arg.0.tag == \"charge\" and process.label == \"checkout\"",
      fields: aql.event_fields(),
    )
  let plan = aql.compile_trigger(query, types.Mfa("shop", "checkout", 1))
  let residual = case plan.residual {
    Some(_) -> "some"
    None -> "none"
  }
  let suggestion = case error {
    aql.UnknownField(_, _, Some(field)) -> field
    _ -> "none"
  }
  io.println("suggestion=" <> suggestion <> " residual=" <> residual)
}
