import gleam/bit_array

pub type Enrollment {
  Enrollment(token_hash: String, expires_at_ms: Int, used: Bool)
}

pub type RelayIdentity {
  RelayIdentity(algorithm: String, public_key: BitArray)
}

pub type EnrollmentResult {
  EnrollmentResult(state: Enrollment, identity: RelayIdentity)
}

pub type EnrollmentError {
  AlreadyUsed
  Expired
  InvalidToken
  InvalidPublicKey
}

pub fn new(token_hash: String, expires_at_ms expires_at_ms: Int) -> Enrollment {
  Enrollment(token_hash, expires_at_ms, False)
}

pub fn enroll(
  state: Enrollment,
  presented_hash presented_hash: String,
  public_key public_key: BitArray,
  now_ms now_ms: Int,
) -> Result(EnrollmentResult, EnrollmentError) {
  case
    state.used,
    now_ms > state.expires_at_ms,
    presented_hash == state.token_hash,
    bit_array.byte_size(public_key) == 32
  {
    True, _, _, _ -> Error(AlreadyUsed)
    _, True, _, _ -> Error(Expired)
    _, _, False, _ -> Error(InvalidToken)
    _, _, _, False -> Error(InvalidPublicKey)
    False, False, True, True ->
      Ok(EnrollmentResult(
        state: Enrollment(..state, used: True),
        identity: RelayIdentity("Ed25519", public_key),
      ))
  }
}
