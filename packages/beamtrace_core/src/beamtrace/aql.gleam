import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/order.{Gt, Lt}
import gleam/string

pub type Value {
  StringValue(String)
  IntValue(Int)
  FloatValue(Float)
  BoolValue(Bool)
  DurationValue(milliseconds: Int)
}

pub type Comparator {
  Equal
  NotEqual
  GreaterThan
  GreaterThanOrEqual
  LessThan
  LessThanOrEqual
}

pub type Query {
  Compare(field: String, comparator: Comparator, value: Value)
  And(left: Query, right: Query)
  Or(left: Query, right: Query)
  Not(query: Query)
}

pub type AqlError {
  AqlError(offset: Int, message: String)
}

pub type AgentPlan {
  AgentPlan(match_spec_fields: List(String), residual_fields: List(String))
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

pub fn parse(source: String) -> Result(Query, AqlError) {
  use tokens <- result_try(lex(source))
  use parsed <- result_try(parse_or(tokens))
  let #(query, rest) = parsed
  case rest {
    [Token(End, _)] -> Ok(query)
    [Token(_, offset), ..] -> Error(AqlError(offset, "unexpected token"))
    [] -> Ok(query)
  }
}

fn parse_or(tokens: List(Token)) -> Result(#(Query, List(Token)), AqlError) {
  use parsed <- result_try(parse_and(tokens))
  let #(left, rest) = parsed
  parse_or_tail(left, rest)
}

fn parse_or_tail(
  left: Query,
  tokens: List(Token),
) -> Result(#(Query, List(Token)), AqlError) {
  case tokens {
    [Token(OrToken, _), ..rest] -> {
      use parsed <- result_try(parse_and(rest))
      let #(right, remaining) = parsed
      parse_or_tail(Or(left, right), remaining)
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_and(tokens: List(Token)) -> Result(#(Query, List(Token)), AqlError) {
  use parsed <- result_try(parse_unary(tokens))
  let #(left, rest) = parsed
  parse_and_tail(left, rest)
}

fn parse_and_tail(
  left: Query,
  tokens: List(Token),
) -> Result(#(Query, List(Token)), AqlError) {
  case tokens {
    [Token(AndToken, _), ..rest] -> {
      use parsed <- result_try(parse_unary(rest))
      let #(right, remaining) = parsed
      parse_and_tail(And(left, right), remaining)
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_unary(tokens: List(Token)) -> Result(#(Query, List(Token)), AqlError) {
  case tokens {
    [Token(NotToken, _), ..rest] -> {
      use parsed <- result_try(parse_unary(rest))
      let #(query, remaining) = parsed
      Ok(#(Not(query), remaining))
    }
    [Token(LeftParen, _), ..rest] -> {
      use parsed <- result_try(parse_or(rest))
      let #(query, remaining) = parsed
      case remaining {
        [Token(RightParen, _), ..tail] -> Ok(#(query, tail))
        [Token(_, offset), ..] -> Error(AqlError(offset, "expected ')'"))
        [] -> Error(AqlError(0, "expected ')'"))
      }
    }
    _ -> parse_comparison(tokens)
  }
}

fn parse_comparison(
  tokens: List(Token),
) -> Result(#(Query, List(Token)), AqlError) {
  case tokens {
    [Token(Identifier(field), _), Token(operator, operator_offset), ..rest] -> {
      use comparator <- result_try(comparator(operator, operator_offset))
      case rest {
        [Token(kind, value_offset), ..remaining] -> {
          use value <- result_try(value(kind, value_offset))
          Ok(#(Compare(field, comparator, value), remaining))
        }
        [] -> Error(AqlError(operator_offset + 1, "expected value"))
      }
    }
    [Token(End, offset), ..] -> Error(AqlError(offset, "expected comparison"))
    [Token(_, offset), ..] -> Error(AqlError(offset, "expected field name"))
    [] -> Error(AqlError(0, "expected comparison"))
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
    _ -> Error(AqlError(offset, "expected comparison operator"))
  }
}

fn value(kind: TokenKind, offset: Int) -> Result(Value, AqlError) {
  case kind {
    Quoted(value) -> Ok(StringValue(value))
    Boolean(value) -> Ok(BoolValue(value))
    Numeric(value) -> parse_numeric(value, offset)
    Identifier(value) -> Ok(StringValue(value))
    _ -> Error(AqlError(offset, "expected value"))
  }
}

fn parse_numeric(source: String, offset: Int) -> Result(Value, AqlError) {
  case duration_suffix(source) {
    #(number, SomeUnit(multiplier, divisor)) ->
      case int.parse(number) {
        Ok(value) -> Ok(DurationValue(value * multiplier / divisor))
        Error(_) -> Error(AqlError(offset, "invalid duration"))
      }
    #(_, NoUnit) ->
      case int.parse(source), float.parse(source) {
        Ok(value), _ -> Ok(IntValue(value))
        _, Ok(value) -> Ok(FloatValue(value))
        _, _ -> Error(AqlError(offset, "invalid number"))
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

pub fn compile_agent(query: Query) -> AgentPlan {
  let fields = fields(query, []) |> list.reverse |> unique([])
  let #(safe, residual) = split_fields(fields, [], [])
  AgentPlan(safe, residual)
}

fn fields(query: Query, accumulator: List(String)) -> List(String) {
  case query {
    Compare(field, _, _) -> [field, ..accumulator]
    And(left, right) | Or(left, right) ->
      fields(right, fields(left, accumulator))
    Not(query) -> fields(query, accumulator)
  }
}

fn unique(values: List(String), seen: List(String)) -> List(String) {
  case values {
    [] -> list.reverse(seen)
    [value, ..rest] ->
      case list.contains(seen, value) {
        True -> unique(rest, seen)
        False -> unique(rest, [value, ..seen])
      }
  }
}

fn split_fields(
  values: List(String),
  safe: List(String),
  residual: List(String),
) -> #(List(String), List(String)) {
  case values {
    [] -> #(list.reverse(safe), list.reverse(residual))
    [value, ..rest] ->
      case agent_safe(value) {
        True -> split_fields(rest, [value, ..safe], residual)
        False -> split_fields(rest, safe, [value, ..residual])
      }
  }
}

fn agent_safe(field: String) -> Bool {
  list.contains(
    ["message.tag", "message.size", "mfa", "module", "function", "arity"],
    field,
  )
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
        "" -> Error(AqlError(offset, "unexpected character"))
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
    [] -> Error(AqlError(offset, "unterminated string"))
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
