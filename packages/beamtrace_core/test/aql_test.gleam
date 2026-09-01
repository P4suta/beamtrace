import beamtrace/aql
import beamtrace/types
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import qcheck

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
  aql.parse("duration >") |> should.equal(Error(aql.ExpectedValue(10)))
  let assert Error(error) = aql.parse("duration >")
  error.offset |> should.equal(10)
}

pub fn each_failure_reports_its_typed_variant_test() {
  aql.parse("== 1") |> should.equal(Error(aql.ExpectedField(0)))
  aql.parse("duration !")
  |> should.equal(Error(aql.UnexpectedCharacter(9, "!")))
  aql.parse("name == \"open") |> should.equal(Error(aql.UnterminatedString(13)))
  aql.parse("duration > 1x and a == 1")
  |> should.equal(Error(aql.InvalidNumber(11, "1x")))
  aql.parse("duration > 1.5ms")
  |> should.equal(Error(aql.InvalidDuration(11, "1.5ms")))
  aql.parse("duration ==")
  |> should.equal(Error(aql.ExpectedValue(11)))
  aql.parse("duration 5") |> should.equal(Error(aql.ExpectedComparator(9)))
  aql.parse("(a == 1") |> should.equal(Error(aql.UnclosedParenthesis(0)))
  aql.parse("a == 1 b == 2")
  |> should.equal(Error(aql.UnexpectedToken(7, "b")))
}

pub fn error_messages_name_the_problem_and_offset_test() {
  aql.error_message(aql.ExpectedValue(10))
  |> should.equal("expected a value at offset 10")
  aql.error_message(aql.UnexpectedToken(4, ")"))
  |> should.equal("unexpected ')' at offset 4")
  aql.error_message(aql.UnknownField(0, "message.tga", Some("message.tag")))
  |> should.equal(
    "unknown field 'message.tga' at offset 0; did you mean 'message.tag'?",
  )
  aql.error_message(aql.UnknownField(0, "zzz", None))
  |> should.equal("unknown field 'zzz' at offset 0")
}

pub fn error_report_places_a_caret_under_the_grapheme_offset_test() {
  let source = "duration >"
  let assert Error(error) = aql.parse(source)
  aql.error_report(source: source, error: error)
  |> should.equal("duration >\n          ^ expected a value at offset 10")
}

pub fn error_report_counts_multibyte_graphemes_once_test() {
  let source = "tag == \"あい\" and"
  let assert Error(error) = aql.parse(source)
  error |> should.equal(aql.ExpectedField(15))
  aql.error_report(source: source, error: error)
  |> should.equal(
    "tag == \"あい\" and\n"
    <> string.repeat(" ", 15)
    <> "^ expected a field name at offset 15",
  )
}

pub fn parse_for_accepts_catalogued_and_wildcard_fields_test() {
  let assert Ok(_) =
    aql.parse_for(
      "arg.3.tag == \"$gen_call\" and node == \"a@b\"",
      fields: aql.event_fields(),
    )
  let assert Ok(_) =
    aql.parse_for("message.size > 100", fields: aql.event_fields())
}

pub fn parse_for_rejects_unknown_fields_with_a_suggestion_test() {
  aql.parse_for("message.tga == \"x\"", fields: aql.event_fields())
  |> should.equal(
    Error(aql.UnknownField(0, "message.tga", Some("message.tag"))),
  )
}

pub fn parse_for_substitutes_wildcard_segments_in_suggestions_test() {
  aql.parse_for("arg.0.tga == \"x\"", fields: aql.event_fields())
  |> should.equal(Error(aql.UnknownField(0, "arg.0.tga", Some("arg.0.tag"))))
}

pub fn parse_for_omits_suggestions_beyond_edit_distance_two_test() {
  aql.parse_for("zzzzz == 1", fields: aql.event_fields())
  |> should.equal(Error(aql.UnknownField(0, "zzzzz", None)))
}

pub fn parse_for_rejects_wildcard_segments_that_are_not_indexes_test() {
  aql.parse_for("arg.first.tag == \"x\"", fields: ["arg.*.tag"])
  |> should.equal(Error(aql.UnknownField(0, "arg.first.tag", None)))
}

pub fn event_fields_cover_the_capture_context_test() {
  let fields = aql.event_fields()
  [
    "node", "process.pid", "root_id", "event.kind", "exact", "timestamp_ns",
    "mfa", "module", "function", "arity", "arg.count", "arg.*.tag", "arg.*.size",
    "arg.*.type", "message.tag", "message.size", "message.type", "process.label",
    "process.logical_id", "process.registered_name", "process.initial_call",
    "process.ancestor", "process.child_id", "process.restart_proximity_ms",
  ]
  |> list.each(fn(field) { list.contains(fields, field) |> should.be_true() })
}

pub fn parse_errors_stay_within_grapheme_bounds_property_test() {
  let config =
    qcheck.config(
      test_count: 500,
      max_retries: 1,
      seed: qcheck.seed(20_260_901),
    )
  use source <- qcheck.run(config, qcheck.string())
  case aql.parse(source) {
    Ok(_) -> Nil
    Error(error) -> {
      let inside =
        error.offset >= 0 && error.offset <= string.length(source) + 1
      should.be_true(inside)
    }
  }
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
