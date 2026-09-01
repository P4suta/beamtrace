import beamtrace/privacy
import beamtrace/types
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn fingerprint(value: String) -> String {
  "session-hash:" <> value
}

pub fn metadata_hides_scalar_and_binary_contents_test() {
  let secret = "SENTINEL-secret-never-leak"
  let scalar =
    privacy.shape(types.RawString(secret), types.Metadata, fingerprint)
  let binary =
    privacy.shape(types.RawBinary(secret, 26), types.Metadata, fingerprint)

  scalar
  |> should.equal(types.Scalar("string", None, Some("session-hash:" <> secret)))
  binary
  |> should.equal(types.BinaryMetadata(
    26,
    None,
    Some("session-hash:" <> secret),
  ))

  privacy.render(scalar) |> string.contains(secret) |> should.be_false()
  privacy.render(binary) |> string.contains(secret) |> should.be_false()
}

pub fn constructor_shape_is_preserved_without_values_test() {
  privacy.shape(
    types.RawConstructor("Ok", [types.RawString("token")]),
    types.Metadata,
    fingerprint,
  )
  |> should.equal(
    types.Constructor("Ok", [
      types.Scalar("string", None, Some("session-hash:token")),
    ]),
  )
}

pub fn raw_mode_redacts_named_keys_and_limits_depth_test() {
  let policy =
    types.RawPolicy(
      redact_keys: ["password", "authorization"],
      max_depth: 1,
      max_binary_bytes: 4,
    )

  privacy.shape(
    types.RawMap([
      #(types.RawAtom("password"), types.RawString("hunter2")),
      #(types.RawAtom("profile"), types.RawTuple([types.RawString("nested")])),
    ]),
    types.Raw(policy),
    fingerprint,
  )
  |> should.equal(
    types.BoundedMap(2, [
      #(types.Atom("password"), types.Redacted("key policy")),
      #(types.Atom("profile"), types.Tuple([types.Redacted("depth limit")])),
    ]),
  )
}

pub fn raw_mode_honours_case_insensitive_custom_redaction_keys_test() {
  let policy =
    types.RawPolicy(
      redact_keys: ["session_id"],
      max_depth: 3,
      max_binary_bytes: 16,
    )

  privacy.shape(
    types.RawMap([
      #(types.RawString("SESSION_ID"), types.RawString("do-not-export")),
    ]),
    types.Raw(policy),
    fingerprint,
  )
  |> should.equal(
    types.BoundedMap(1, [
      #(
        types.Scalar(
          "string",
          Some("SESSION_ID"),
          Some("session-hash:SESSION_ID"),
        ),
        types.Redacted("key policy"),
      ),
    ]),
  )
}
