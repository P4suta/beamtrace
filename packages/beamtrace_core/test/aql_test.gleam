import beamtrace/aql
import beamtrace/types
import gleam/dict
import gleam/option.{Some}
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

pub fn malformed_query_reports_source_offset_test() {
  let assert Error(error) = aql.parse("duration >")
  error.offset |> should.equal(10)
}

pub fn trigger_plan_pushes_fixed_mfa_and_argument_shape_without_losing_residual_test() {
  let assert Ok(query) =
    aql.parse(
      "module == shop and arg.0.tag == \"$gen_call\" and process.label == checkout",
    )
  let plan = aql.compile_trigger(query, types.Mfa("shop", "checkout", 1))

  plan.predicate
  |> should.equal(aql.AgentArgTag(0, aql.AgentEqual, "$gen_call"))
  plan.residual
  |> should.equal(
    Some(aql.Compare("process.label", aql.Equal, aql.StringValue("checkout"))),
  )
}

pub fn impossible_fixed_trigger_filter_is_rejected_before_target_mutation_test() {
  let assert Ok(query) = aql.parse("module == other")
  aql.compile_trigger(query, types.Mfa("shop", "checkout", 1)).predicate
  |> should.equal(aql.AgentNever)
}

pub fn mixed_safe_and_residual_or_is_not_unsafely_pushed_down_test() {
  let assert Ok(query) =
    aql.parse("arg.0.type == tuple or process.label == checkout")
  let plan = aql.compile_trigger(query, types.Mfa("shop", "checkout", 1))

  plan.predicate |> should.equal(aql.AgentAlways)
  plan.residual |> should.equal(Some(query))
}
