import beamtrace/aql
import gleam/dict
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn parses_and_evaluates_boolean_duration_expression_test() {
  let assert Ok(query) =
    aql.parse("message.tag == \"$gen_call\" and duration > 250ms")
  let context =
    dict.from_list([
      #("message.tag", aql.StringValue("$gen_call")),
      #("duration", aql.DurationValue(300)),
    ])

  aql.evaluate(query, context) |> should.be_true()
}

pub fn precedence_places_and_before_or_test() {
  let assert Ok(query) =
    aql.parse("anomaly == true or duration > 10ms and mfa == \"shop:buy/1\"")
  let context =
    dict.from_list([
      #("anomaly", aql.BoolValue(False)),
      #("duration", aql.DurationValue(20)),
      #("mfa", aql.StringValue("shop:buy/1")),
    ])

  aql.evaluate(query, context) |> should.be_true()
}

pub fn safe_agent_subset_is_split_from_residual_test() {
  let assert Ok(query) =
    aql.parse("message.tag == \"$gen_call\" and process.label == \"checkout\"")
  let plan = aql.compile_agent(query)

  plan.match_spec_fields |> should.equal(["message.tag"])
  plan.residual_fields |> should.equal(["process.label"])
}

pub fn malformed_query_reports_source_offset_test() {
  let assert Error(error) = aql.parse("duration >")
  error.offset |> should.equal(10)
}
