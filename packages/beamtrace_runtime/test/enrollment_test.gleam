import beamtrace_runtime/enrollment
import gleam/bit_array
import gleeunit/should

fn public_key() {
  bit_array.base16_decode(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  |> should.be_ok()
}

pub fn relay_enrollment_is_one_time_test() {
  let state = enrollment.new("token-hash", expires_at_ms: 1000)
  let assert Ok(result) =
    enrollment.enroll(
      state,
      presented_hash: "token-hash",
      public_key: public_key(),
      now_ms: 900,
    )
  result.identity.algorithm |> should.equal("Ed25519")
  result.identity.public_key |> should.equal(public_key())

  enrollment.enroll(result.state, "token-hash", public_key(), 901)
  |> should.equal(Error(enrollment.AlreadyUsed))
}

pub fn invalid_public_key_is_rejected_without_consuming_token_test() {
  let state = enrollment.new("token", 100)
  enrollment.enroll(state, "token", <<1, 2, 3>>, 1)
  |> should.equal(Error(enrollment.InvalidPublicKey))
  enrollment.enroll(state, "token", public_key(), 2) |> should.be_ok()
}
