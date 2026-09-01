//// Safe parsing, evaluation, and agent planning for BeamTrace Query Language.
////
//// Parsing returns a typed, offset-bearing `AqlError` renderable with
//// `error_message` or the caret-annotated `error_report`; `parse_for`
//// additionally rejects fields outside a caller-supplied vocabulary such as
//// `event_fields`. Evaluation reads only the supplied context and
//// compilation emits a bounded predicate plan, never arbitrary code.
//// Parsing and evaluation are linear in query size and pure on Erlang and
//// JavaScript.

import beamtrace/types
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Gt, Lt}
import gleam/result
import gleam/string

/// A typed literal accepted by AQL comparisons.
pub type Value {
  StringValue(String)
  IntValue(Int)
  FloatValue(Float)
  BoolValue(Bool)
  DurationValue(milliseconds: Int)
}

/// The comparison operations expressible by AQL.
pub type Comparator {
  Equal
  NotEqual
  GreaterThan
  GreaterThanOrEqual
  LessThan
  LessThanOrEqual
}

/// A finite, side-effect-free AQL expression tree.
pub type Query {
  Compare(field: String, comparator: Comparator, value: Value)
  And(left: Query, right: Query)
  Or(left: Query, right: Query)
  Not(query: Query)
}

/// A parse failure at a zero-based grapheme offset into the source.
///
/// Every variant carries the offset first, so `error.offset` works on all of
/// them. Render one line with `error_message` or a caret-annotated report
/// with `error_report`.
pub type AqlError {
  /// A character that cannot start any AQL token.
  UnexpectedCharacter(offset: Int, character: String)
  /// A double-quoted string that never closes.
  UnterminatedString(offset: Int)
  /// A numeric literal that parses as neither integer nor float.
  InvalidNumber(offset: Int, text: String)
  /// A duration literal whose number part is not an integer.
  InvalidDuration(offset: Int, text: String)
  /// A comparison was expected but no field name is present.
  ExpectedField(offset: Int)
  /// A field name is present but no comparison operator follows.
  ExpectedComparator(offset: Int)
  /// A comparison operator is present but no value follows.
  ExpectedValue(offset: Int)
  /// A `(` at this offset is never closed by `)`.
  UnclosedParenthesis(offset: Int)
  /// A well-formed query already ended before this leftover token.
  UnexpectedToken(offset: Int, lexeme: String)
  /// A field outside the vocabulary given to `parse_for`, with the closest
  /// catalogued field when one is within edit distance two.
  UnknownField(offset: Int, field: String, suggestion: Option(String))
}

/// Equality operations supported by dependency-free target match-specs.
pub type AgentComparator {
  AgentEqual
  AgentNotEqual
}

/// A finite predicate that the dependency-free target agent can safely turn
/// into an OTP trace match-spec. It intentionally cannot inspect scalar
/// values, binaries, process state, or any field that would weaken privacy.
pub type AgentPredicate {
  AgentAlways
  AgentNever
  AgentArgTag(index: Int, comparator: AgentComparator, tag: String)
  AgentArgType(index: Int, comparator: AgentComparator, kind: String)
  AgentAnd(left: AgentPredicate, right: AgentPredicate)
  AgentOr(left: AgentPredicate, right: AgentPredicate)
  AgentNot(predicate: AgentPredicate)
}

/// A safe target predicate paired with any relay-side residual query.
pub type TriggerPlan {
  TriggerPlan(predicate: AgentPredicate, residual: Option(Query))
}

type Token {
  Token(kind: TokenKind, offset: Int)
}

type TokenKind {
  Identifier(String)
  Quoted(String)
  Numeric(String)
  Boolean(Bool)
  AndToken
  OrToken
  NotToken
  EqualToken
  NotEqualToken
  GreaterToken
  GreaterEqualToken
  LessToken
  LessEqualToken
  LeftParen
  RightParen
  End
}

/// Parse one AQL expression in O(source length). Invalid syntax returns the
/// first typed `AqlError`; parsing never performs I/O or executes input.
/// Field names are not checked here — use `parse_for` when the evaluation
/// context is known.
pub fn parse(source: String) -> Result(Query, AqlError) {
  parse_with(source, None)
}

/// Parse one AQL expression and reject fields outside the given vocabulary.
///
/// Each entry is a literal field name or a pattern whose `*` segment matches
/// one non-negative integer (for example `arg.*.tag`). An unknown field
/// fails at its source offset with the closest catalogued field as a
/// suggestion when it is within edit distance two. Use `event_fields` for
/// the capture event vocabulary.
pub fn parse_for(
  source: String,
  fields fields: List(String),
) -> Result(Query, AqlError) {
  parse_with(source, Some(fields))
}

/// The field vocabulary available to `--where` predicates evaluated against
/// capture events, including the `arg.*.…` patterns whose `*` stands for a
/// zero-based argument index. This list is the single source the runtime,
/// the CLI help, and the documentation render from.
pub fn event_fields() -> List(String) {
  [
    "node", "process.pid", "root_id", "event.kind", "exact", "timestamp_ns",
    "process.label", "process.logical_id", "process.registered_name",
    "process.initial_call", "process.ancestor", "process.child_id",
    "process.restart_proximity_ms", "mfa", "module", "function", "arity",
    "arg.count", "arg.*.tag", "arg.*.size", "arg.*.type", "message.tag",
    "message.size", "message.type",
  ]
}

/// Render a one-line, stable explanation of a parse failure. The offset is
/// zero-based and counts graphemes; nothing from the runtime environment
/// leaks into the message.
pub fn error_message(error: AqlError) -> String {
  case error {
    UnexpectedCharacter(offset, character) ->
      "unexpected character '" <> character <> "' at offset " <> at(offset)
    UnterminatedString(offset) -> "unterminated string at offset " <> at(offset)
    InvalidNumber(offset, text) ->
      "invalid number '" <> text <> "' at offset " <> at(offset)
    InvalidDuration(offset, text) ->
      "invalid duration '" <> text <> "' at offset " <> at(offset)
    ExpectedField(offset) -> "expected a field name at offset " <> at(offset)
    ExpectedComparator(offset) ->
      "expected a comparison operator at offset " <> at(offset)
    ExpectedValue(offset) -> "expected a value at offset " <> at(offset)
    UnclosedParenthesis(offset) -> "unclosed '(' at offset " <> at(offset)
    UnexpectedToken(offset, lexeme) ->
      "unexpected '" <> lexeme <> "' at offset " <> at(offset)
    UnknownField(offset, field, suggestion) ->
      "unknown field '"
      <> field
      <> "' at offset "
      <> at(offset)
      <> case suggestion {
        Some(candidate) -> "; did you mean '" <> candidate <> "'?"
        None -> ""
      }
  }
}

/// Render the source with a caret under the failing grapheme, followed by
/// `error_message`. The report assumes a single-line query rendered in a
/// monospaced context; offsets count graphemes, so multi-byte characters
/// stay aligned.
pub fn error_report(source source: String, error error: AqlError) -> String {
  source
  <> "\n"
  <> string.repeat(" ", error.offset)
  <> "^ "
  <> error_message(error)
}

fn at(offset: Int) -> String {
  int.to_string(offset)
}

fn check_field(
  field: String,
  offset: Int,
  fields: Option(List(String)),
) -> Result(Nil, AqlError) {
  case fields {
    None -> Ok(Nil)
    Some(patterns) ->
      case list.any(patterns, matches_pattern(field, _)) {
        True -> Ok(Nil)
        False -> Error(UnknownField(offset, field, suggest(field, patterns)))
      }
  }
}

fn matches_pattern(field: String, pattern: String) -> Bool {
  segments_match(string.split(field, "."), string.split(pattern, "."))
}

fn segments_match(field: List(String), pattern: List(String)) -> Bool {
  case field, pattern {
    [], [] -> True
    [segment, ..field_rest], [expected, ..pattern_rest] ->
      case segment == expected || { expected == "*" && is_index(segment) } {
        True -> segments_match(field_rest, pattern_rest)
        False -> False
      }
    _, _ -> False
  }
}

fn is_index(segment: String) -> Bool {
  segment != ""
  && list.all(string.to_graphemes(segment), string.contains("0123456789", _))
}

fn suggest(field: String, patterns: List(String)) -> Option(String) {
  let candidates =
    patterns
    |> list.map(substitute_wildcard(_, string.split(field, ".")))
    |> list.sort(string.compare)
  list.fold(candidates, None, fn(best, candidate) {
    let distance = edit_distance(field, candidate)
    case distance <= 2 {
      False -> best
      True ->
        case best {
          None -> Some(#(candidate, distance))
          Some(#(_, best_distance)) if distance < best_distance ->
            Some(#(candidate, distance))
          Some(_) -> best
        }
    }
  })
  |> option.map(fn(pair) { pair.0 })
}

fn substitute_wildcard(
  pattern: String,
  field_segments: List(String),
) -> String {
  let pattern_segments = string.split(pattern, ".")
  case list.length(pattern_segments) == list.length(field_segments) {
    False -> pattern
    True ->
      list.map2(pattern_segments, field_segments, fn(expected, actual) {
        case expected == "*" && is_index(actual) {
          True -> actual
          False -> expected
        }
      })
      |> string.join(".")
  }
}

fn edit_distance(left: String, right: String) -> Int {
  let left = string.to_graphemes(left)
  let right = string.to_graphemes(right)
  let first_row = count_up(0, list.length(right), [])
  list.fold(left, #(first_row, 1), fn(state, left_char) {
    let #(previous_row, row_number) = state
    let next_row = distance_row(previous_row, right, left_char, [row_number])
    #(next_row, row_number + 1)
  }).0
  |> list.last
  |> result.unwrap(0)
}

fn count_up(next: Int, limit: Int, accumulator: List(Int)) -> List(Int) {
  case next > limit {
    True -> list.reverse(accumulator)
    False -> count_up(next + 1, limit, [next, ..accumulator])
  }
}

fn distance_row(
  previous_row: List(Int),
  right: List(String),
  left_char: String,
  accumulator: List(Int),
) -> List(Int) {
  case previous_row, right, accumulator {
    [diagonal, above, ..previous_rest], [right_char, ..right_rest], [left, ..]
    -> {
      let substitution = case left_char == right_char {
        True -> diagonal
        False -> diagonal + 1
      }
      let cost = int.min(substitution, int.min(above + 1, left + 1))
      distance_row([above, ..previous_rest], right_rest, left_char, [
        cost,
        ..accumulator
      ])
    }
    _, _, _ -> list.reverse(accumulator)
  }
}

fn token_lexeme(kind: TokenKind) -> String {
  case kind {
    Identifier(word) -> word
    Quoted(value) -> "\"" <> value <> "\""
    Numeric(value) -> value
    Boolean(True) -> "true"
    Boolean(False) -> "false"
    AndToken -> "and"
    OrToken -> "or"
    NotToken -> "not"
    EqualToken -> "=="
    NotEqualToken -> "!="
    GreaterToken -> ">"
    GreaterEqualToken -> ">="
    LessToken -> "<"
    LessEqualToken -> "<="
    LeftParen -> "("
    RightParen -> ")"
    End -> "end of query"
  }
}

fn parse_with(
  source: String,
  fields: Option(List(String)),
) -> Result(Query, AqlError) {
  use tokens <- result_try(lex(source))
  use parsed <- result_try(parse_or(tokens, fields))
  let #(query, rest) = parsed
  case rest {
    [Token(End, _)] -> Ok(query)
    [Token(kind, offset), ..] ->
      Error(UnexpectedToken(offset, token_lexeme(kind)))
    [] -> Ok(query)
  }
}

fn parse_or(
  tokens: List(Token),
  fields: Option(List(String)),
) -> Result(#(Query, List(Token)), AqlError) {
  use parsed <- result_try(parse_and(tokens, fields))
  let #(left, rest) = parsed
  parse_or_tail(left, rest, fields)
}

fn parse_or_tail(
  left: Query,
  tokens: List(Token),
  fields: Option(List(String)),
) -> Result(#(Query, List(Token)), AqlError) {
  case tokens {
    [Token(OrToken, _), ..rest] -> {
      use parsed <- result_try(parse_and(rest, fields))
      let #(right, remaining) = parsed
      parse_or_tail(Or(left, right), remaining, fields)
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_and(
  tokens: List(Token),
  fields: Option(List(String)),
) -> Result(#(Query, List(Token)), AqlError) {
  use parsed <- result_try(parse_unary(tokens, fields))
  let #(left, rest) = parsed
  parse_and_tail(left, rest, fields)
}

fn parse_and_tail(
  left: Query,
  tokens: List(Token),
  fields: Option(List(String)),
) -> Result(#(Query, List(Token)), AqlError) {
  case tokens {
    [Token(AndToken, _), ..rest] -> {
      use parsed <- result_try(parse_unary(rest, fields))
      let #(right, remaining) = parsed
      parse_and_tail(And(left, right), remaining, fields)
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_unary(
  tokens: List(Token),
  fields: Option(List(String)),
) -> Result(#(Query, List(Token)), AqlError) {
  case tokens {
    [Token(NotToken, _), ..rest] -> {
      use parsed <- result_try(parse_unary(rest, fields))
      let #(query, remaining) = parsed
      Ok(#(Not(query), remaining))
    }
    [Token(LeftParen, open_offset), ..rest] -> {
      use parsed <- result_try(parse_or(rest, fields))
      let #(query, remaining) = parsed
      case remaining {
        [Token(RightParen, _), ..tail] -> Ok(#(query, tail))
        _ -> Error(UnclosedParenthesis(open_offset))
      }
    }
    _ -> parse_comparison(tokens, fields)
  }
}

fn parse_comparison(
  tokens: List(Token),
  fields: Option(List(String)),
) -> Result(#(Query, List(Token)), AqlError) {
  case tokens {
    [
      Token(Identifier(field), field_offset),
      Token(operator, operator_offset),
      ..rest
    ] -> {
      use Nil <- result_try(check_field(field, field_offset, fields))
      use comparator <- result_try(comparator(operator, operator_offset))
      case rest {
        [Token(kind, value_offset), ..remaining] -> {
          use value <- result_try(value(kind, value_offset))
          Ok(#(Compare(field, comparator, value), remaining))
        }
        [] -> Error(ExpectedValue(operator_offset + 1))
      }
    }
    [Token(_, offset), ..] -> Error(ExpectedField(offset))
    [] -> Error(ExpectedField(0))
  }
}

fn comparator(kind: TokenKind, offset: Int) -> Result(Comparator, AqlError) {
  case kind {
    EqualToken -> Ok(Equal)
    NotEqualToken -> Ok(NotEqual)
    GreaterToken -> Ok(GreaterThan)
    GreaterEqualToken -> Ok(GreaterThanOrEqual)
    LessToken -> Ok(LessThan)
    LessEqualToken -> Ok(LessThanOrEqual)
    _ -> Error(ExpectedComparator(offset))
  }
}

fn value(kind: TokenKind, offset: Int) -> Result(Value, AqlError) {
  case kind {
    Quoted(value) -> Ok(StringValue(value))
    Boolean(value) -> Ok(BoolValue(value))
    Numeric(value) -> parse_numeric(value, offset)
    Identifier(value) -> Ok(StringValue(value))
    _ -> Error(ExpectedValue(offset))
  }
}

fn parse_numeric(source: String, offset: Int) -> Result(Value, AqlError) {
  case duration_suffix(source) {
    #(number, SomeUnit(multiplier, divisor)) ->
      case int.parse(number) {
        Ok(value) -> Ok(DurationValue(value * multiplier / divisor))
        Error(_) -> Error(InvalidDuration(offset, source))
      }
    #(_, NoUnit) ->
      case int.parse(source), float.parse(source) {
        Ok(value), _ -> Ok(IntValue(value))
        _, Ok(value) -> Ok(FloatValue(value))
        _, _ -> Error(InvalidNumber(offset, source))
      }
  }
}

type Unit {
  NoUnit
  SomeUnit(multiplier: Int, divisor: Int)
}

fn duration_suffix(source: String) -> #(String, Unit) {
  case
    string.ends_with(source, "ms"),
    string.ends_with(source, "us"),
    string.ends_with(source, "ns"),
    string.ends_with(source, "s")
  {
    True, _, _, _ -> #(string.drop_end(source, 2), SomeUnit(1, 1))
    _, True, _, _ -> #(string.drop_end(source, 2), SomeUnit(1, 1000))
    _, _, True, _ -> #(string.drop_end(source, 2), SomeUnit(1, 1_000_000))
    _, _, _, True -> #(string.drop_end(source, 1), SomeUnit(1000, 1))
    _, _, _, _ -> #(source, NoUnit)
  }
}

/// Evaluate a parsed query against only the supplied fields. Missing or
/// type-incompatible fields are false. Work is O(query size) plus dictionary
/// lookups and cannot fail.
pub fn evaluate(query: Query, context: Dict(String, Value)) -> Bool {
  case query {
    Compare(field, comparator, expected) ->
      case dict.get(context, field) {
        Ok(actual) -> compare_values(actual, comparator, expected)
        Error(_) -> False
      }
    And(left, right) -> evaluate(left, context) && evaluate(right, context)
    Or(left, right) -> evaluate(left, context) || evaluate(right, context)
    Not(query) -> !evaluate(query, context)
  }
}

fn compare_values(
  actual: Value,
  comparator: Comparator,
  expected: Value,
) -> Bool {
  case comparator {
    Equal -> actual == expected
    NotEqual -> actual != expected
    _ -> compare_ordered(actual, comparator, expected)
  }
}

fn compare_ordered(
  actual: Value,
  comparator: Comparator,
  expected: Value,
) -> Bool {
  case numeric_value(actual), numeric_value(expected) {
    Ok(left), Ok(right) ->
      case comparator {
        GreaterThan -> left >. right
        GreaterThanOrEqual -> left >=. right
        LessThan -> left <. right
        LessThanOrEqual -> left <=. right
        _ -> False
      }
    _, _ ->
      case actual, expected {
        StringValue(left), StringValue(right) ->
          case comparator {
            GreaterThan -> string.compare(left, right) == gt_order()
            GreaterThanOrEqual -> string.compare(left, right) != lt_order()
            LessThan -> string.compare(left, right) == lt_order()
            LessThanOrEqual -> string.compare(left, right) != gt_order()
            _ -> False
          }
        _, _ -> False
      }
  }
}

fn numeric_value(value: Value) -> Result(Float, Nil) {
  case value {
    IntValue(value) -> Ok(int.to_float(value))
    FloatValue(value) -> Ok(value)
    DurationValue(value) -> Ok(int.to_float(value))
    _ -> Error(Nil)
  }
}

fn lt_order() {
  Lt
}

fn gt_order() {
  Gt
}

/// Split an AQL query into a target-safe root predicate and a relay-side
/// residual. Mixed safe/unsafe OR and NOT expressions stay wholly residual;
/// pushing only one branch would incorrectly discard valid roots.
pub fn compile_trigger(query: Query, trigger: types.Mfa) -> TriggerPlan {
  let #(predicate, residual) = split_trigger(query, trigger)
  TriggerPlan(predicate, residual)
}

fn split_trigger(
  query: Query,
  trigger: types.Mfa,
) -> #(AgentPredicate, Option(Query)) {
  case query {
    Compare(field, comparator, value) ->
      compile_comparison(query, field, comparator, value, trigger)
    And(left, right) -> {
      let #(left_predicate, left_residual) = split_trigger(left, trigger)
      let #(right_predicate, right_residual) = split_trigger(right, trigger)
      #(
        simplify_and(left_predicate, right_predicate),
        residual_and(left_residual, right_residual),
      )
    }
    Or(left, right) -> {
      let #(left_predicate, left_residual) = split_trigger(left, trigger)
      let #(right_predicate, right_residual) = split_trigger(right, trigger)
      case left_residual, right_residual {
        None, None -> #(simplify_or(left_predicate, right_predicate), None)
        _, _ -> #(AgentAlways, Some(query))
      }
    }
    Not(inner) -> {
      let #(predicate, residual) = split_trigger(inner, trigger)
      case residual {
        None -> #(simplify_not(predicate), None)
        Some(_) -> #(AgentAlways, Some(query))
      }
    }
  }
}

fn compile_comparison(
  query: Query,
  field: String,
  comparator: Comparator,
  value: Value,
  trigger: types.Mfa,
) -> #(AgentPredicate, Option(Query)) {
  case fixed_trigger_value(field, trigger) {
    Some(actual) ->
      case compare_values(actual, comparator, value) {
        True -> #(AgentAlways, None)
        False -> #(AgentNever, None)
      }
    None ->
      case parse_argument_field(field), agent_comparator(comparator), value {
        Ok(#(index, "tag")), Some(agent_comparator), StringValue(tag)
          if index < trigger.arity
        -> #(AgentArgTag(index, agent_comparator, tag), None)
        Ok(#(index, "type")), Some(agent_comparator), StringValue(kind)
          if index < trigger.arity
        ->
          case valid_argument_type(kind) {
            True -> #(AgentArgType(index, agent_comparator, kind), None)
            False -> #(AgentAlways, Some(query))
          }
        Ok(#(index, _)), _, _ if index >= trigger.arity -> #(AgentNever, None)
        _, _, _ -> #(AgentAlways, Some(query))
      }
  }
}

fn fixed_trigger_value(field: String, trigger: types.Mfa) -> Option(Value) {
  case field {
    "mfa" ->
      Some(StringValue(
        trigger.module
        <> ":"
        <> trigger.function
        <> "/"
        <> int.to_string(trigger.arity),
      ))
    "module" -> Some(StringValue(trigger.module))
    "function" -> Some(StringValue(trigger.function))
    "arity" | "arg.count" -> Some(IntValue(trigger.arity))
    _ -> None
  }
}

fn parse_argument_field(field: String) -> Result(#(Int, String), Nil) {
  case string.split(field, on: ".") {
    ["arg", index_source, property] ->
      case int.parse(index_source) {
        Ok(index) if index >= 0 -> Ok(#(index, property))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn agent_comparator(comparator: Comparator) -> Option(AgentComparator) {
  case comparator {
    Equal -> Some(AgentEqual)
    NotEqual -> Some(AgentNotEqual)
    _ -> None
  }
}

fn valid_argument_type(kind: String) -> Bool {
  list.contains(
    [
      "atom",
      "tuple",
      "list",
      "map",
      "binary",
      "integer",
      "float",
      "pid",
      "reference",
      "port",
      "function",
    ],
    string.lowercase(kind),
  )
}

fn residual_and(left: Option(Query), right: Option(Query)) -> Option(Query) {
  case left, right {
    None, None -> None
    Some(query), None | None, Some(query) -> Some(query)
    Some(left), Some(right) -> Some(And(left, right))
  }
}

fn simplify_and(left: AgentPredicate, right: AgentPredicate) -> AgentPredicate {
  case left, right {
    AgentNever, _ | _, AgentNever -> AgentNever
    AgentAlways, predicate | predicate, AgentAlways -> predicate
    _, _ -> AgentAnd(left, right)
  }
}

fn simplify_or(left: AgentPredicate, right: AgentPredicate) -> AgentPredicate {
  case left, right {
    AgentAlways, _ | _, AgentAlways -> AgentAlways
    AgentNever, predicate | predicate, AgentNever -> predicate
    _, _ -> AgentOr(left, right)
  }
}

fn simplify_not(predicate: AgentPredicate) -> AgentPredicate {
  case predicate {
    AgentAlways -> AgentNever
    AgentNever -> AgentAlways
    AgentNot(inner) -> inner
    _ -> AgentNot(predicate)
  }
}

fn lex(source: String) -> Result(List(Token), AqlError) {
  lex_chars(string.to_graphemes(source), 0, [])
}

fn lex_chars(
  chars: List(String),
  offset: Int,
  accumulator: List(Token),
) -> Result(List(Token), AqlError) {
  case chars {
    [] -> Ok(list.reverse([Token(End, offset), ..accumulator]))
    [char, ..rest]
      if char == " " || char == "\t" || char == "\n" || char == "\r"
    -> lex_chars(rest, offset + 1, accumulator)
    ["(", ..rest] ->
      lex_chars(rest, offset + 1, [Token(LeftParen, offset), ..accumulator])
    [")", ..rest] ->
      lex_chars(rest, offset + 1, [Token(RightParen, offset), ..accumulator])
    ["=", "=", ..rest] ->
      lex_chars(rest, offset + 2, [Token(EqualToken, offset), ..accumulator])
    ["!", "=", ..rest] ->
      lex_chars(rest, offset + 2, [Token(NotEqualToken, offset), ..accumulator])
    [">", "=", ..rest] ->
      lex_chars(rest, offset + 2, [
        Token(GreaterEqualToken, offset),
        ..accumulator
      ])
    ["<", "=", ..rest] ->
      lex_chars(rest, offset + 2, [Token(LessEqualToken, offset), ..accumulator])
    [">", ..rest] ->
      lex_chars(rest, offset + 1, [Token(GreaterToken, offset), ..accumulator])
    ["<", ..rest] ->
      lex_chars(rest, offset + 1, [Token(LessToken, offset), ..accumulator])
    ["\"", ..rest] -> {
      use consumed <- result_try(quoted(rest, offset + 1, []))
      let #(value, remaining, next_offset) = consumed
      lex_chars(remaining, next_offset, [
        Token(Quoted(value), offset),
        ..accumulator
      ])
    }
    _ -> {
      let #(word, remaining, consumed) = word(chars, [], 0)
      case word {
        "" ->
          Error(
            UnexpectedCharacter(offset, case chars {
              [char, ..] -> char
              [] -> ""
            }),
          )
        _ ->
          lex_chars(remaining, offset + consumed, [
            Token(classify_word(word), offset),
            ..accumulator
          ])
      }
    }
  }
}

fn quoted(
  chars: List(String),
  offset: Int,
  accumulator: List(String),
) -> Result(#(String, List(String), Int), AqlError) {
  case chars {
    [] -> Error(UnterminatedString(offset))
    ["\"", ..rest] ->
      Ok(#(string.concat(list.reverse(accumulator)), rest, offset + 1))
    ["\\", "\"", ..rest] -> quoted(rest, offset + 2, ["\"", ..accumulator])
    ["\\", "\\", ..rest] -> quoted(rest, offset + 2, ["\\", ..accumulator])
    [char, ..rest] -> quoted(rest, offset + 1, [char, ..accumulator])
  }
}

fn word(
  chars: List(String),
  accumulator: List(String),
  consumed: Int,
) -> #(String, List(String), Int) {
  case chars {
    [] -> #(string.concat(list.reverse(accumulator)), [], consumed)
    [char, ..rest] ->
      case is_delimiter(char) {
        True -> #(string.concat(list.reverse(accumulator)), chars, consumed)
        False -> word(rest, [char, ..accumulator], consumed + 1)
      }
  }
}

fn classify_word(word: String) -> TokenKind {
  case string.lowercase(word) {
    "and" -> AndToken
    "or" -> OrToken
    "not" -> NotToken
    "true" -> Boolean(True)
    "false" -> Boolean(False)
    _ ->
      case starts_numeric(word) {
        True -> Numeric(word)
        False -> Identifier(word)
      }
  }
}

fn starts_numeric(word: String) -> Bool {
  case string.to_graphemes(word) {
    [first, ..] -> string.contains("-0123456789", first)
    [] -> False
  }
}

fn is_whitespace(char: String) -> Bool {
  list.contains([" ", "\t", "\n", "\r"], char)
}

fn is_delimiter(char: String) -> Bool {
  is_whitespace(char) || string.contains("()=<>!\"", char)
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}
