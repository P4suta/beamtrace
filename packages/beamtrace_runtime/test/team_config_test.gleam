// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/oidc_discovery
import beamtrace_runtime/rbac
import beamtrace_runtime/team_config
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import v2_fixture

pub fn complete_team_environment_resolves_public_oidc_and_roles_test() {
  let source = valid_source()
  let assert Ok(config) = team_config.resolve(source)

  config.bind |> should.equal("127.0.0.1")
  config.data_dir |> should.equal("beamtrace-data")
  config.port |> should.equal(4040)
  config.origin |> should.equal("https://hub.example")
  config.redirect_uri
  |> should.equal("https://hub.example/auth/oidc/callback")
  config.group_roles
  |> should.equal([
    #("beam-admins", rbac.Admin),
    #("beam-investigators", rbac.Investigator),
    #("beam-viewers", rbac.Viewer),
    #("beam-raw", rbac.RawCaptureRole),
  ])
  config.retention_days |> should.equal(7)
  config.raw_retention_days |> should.equal(1)
  config.relay_max_events |> should.equal(1_000_000)
  config.relay_max_bytes |> should.equal(1_073_741_824)
  config.blob_backend |> should.equal(team_config.FilesystemBlobs)
}

pub fn s3_blob_config_is_nonsecret_https_only_and_explicit_test() {
  let source =
    valid_source()
    |> dict.insert("blob_backend", "s3")
    |> dict.insert("s3_endpoint", "https://objects.example:9443")
    |> dict.insert("s3_bucket", "beamtrace-prod")
    |> dict.insert("s3_region", "ap-northeast-1")
    |> dict.insert("s3_prefix", "captures/team-a")
  let assert Ok(config) = team_config.resolve(source)
  config.blob_backend
  |> should.equal(team_config.S3Blobs(
    "https://objects.example:9443",
    "beamtrace-prod",
    "ap-northeast-1",
    "captures/team-a",
  ))

  source
  |> dict.insert("s3_endpoint", "http://objects.example")
  |> team_config.resolve
  |> should.equal(Error(team_config.InvalidUrl("s3_endpoint")))
  source
  |> dict.insert("s3_secret_access_key", "must-not-enter-config")
  |> team_config.resolve
  |> should.equal(Error(team_config.BlobSecretForbidden))
}

pub fn team_config_requires_every_identity_boundary_test() {
  valid_source()
  |> dict.delete("oidc_issuer")
  |> team_config.resolve
  |> should.equal(Error(team_config.Missing("oidc_issuer")))

  valid_source()
  |> dict.insert("oidc_redirect_uri", "https://other.example/callback")
  |> team_config.resolve
  |> should.equal(Error(team_config.RedirectOriginMismatch))
}

pub fn team_hub_rejects_cookies_secrets_and_insecure_urls_test() {
  valid_source()
  |> dict.insert("cookie", "must-never-reach-hub")
  |> team_config.resolve
  |> should.equal(Error(team_config.DistributionCookieForbidden))

  valid_source()
  |> dict.insert("oidc_client_secret", "unsupported")
  |> team_config.resolve
  |> should.equal(Error(team_config.ClientSecretForbidden))

  [
    #("origin", "http://hub.example"),
    #("oidc_authorization_endpoint", "http://id.example/authorize"),
    #("oidc_token_endpoint", "https://user:pass@id.example/token"),
    #("oidc_issuer", "https://id.example?untrusted=true"),
  ]
  |> list.each(fn(invalid) {
    valid_source()
    |> dict.insert(invalid.0, invalid.1)
    |> team_config.resolve
    |> should.equal(Error(team_config.InvalidUrl(invalid.0)))
  })
}

pub fn team_configuration_rejects_private_or_empty_signing_jwks_before_bind_test() {
  valid_source()
  |> dict.insert("oidc_jwks_json", "{\"keys\":[]}")
  |> team_config.resolve
  |> should.equal(Error(team_config.InvalidJwks))

  valid_source()
  |> dict.insert(
    "oidc_jwks_json",
    "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"private\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"AQ\",\"e\":\"Aw\",\"d\":\"secret\"}]}",
  )
  |> team_config.resolve
  |> should.equal(Error(team_config.InvalidJwks))
}

pub fn team_role_mapping_rejects_unknown_or_empty_roles_test() {
  valid_source()
  |> dict.insert("oidc_group_roles", "beam-owners:owner")
  |> team_config.resolve
  |> should.equal(Error(team_config.InvalidRoleMapping("beam-owners:owner")))

  valid_source()
  |> dict.insert("oidc_group_roles", "")
  |> team_config.resolve
  |> should.equal(Error(team_config.InvalidRoleMapping("")))
}

pub fn environment_loader_activates_team_only_explicitly_and_reads_bounded_jwks_test() {
  team_config.load_if_requested_with(dict.new(), fn(_) { Error("unexpected") })
  |> should.equal(Ok(None))
  team_config.load_if_requested_with(
    dict.from_list([#("team", "false")]),
    fn(_) { Error("unexpected") },
  )
  |> should.equal(Ok(None))

  let source =
    valid_source()
    |> dict.delete("oidc_jwks_json")
    |> dict.insert("oidc_jwks_file", "C:/secure/idp.jwks.json")
    |> dict.insert("team", "true")
  let assert Ok(Some(loaded)) =
    team_config.load_if_requested_with(source, fn(path) {
      path |> should.equal("C:/secure/idp.jwks.json")
      Ok(v2_fixture.public_jwks)
    })
  loaded.jwks_json |> should.equal(v2_fixture.public_jwks)

  team_config.load_if_requested_with(source, fn(_) { Error("access_denied") })
  |> should.equal(
    Error(team_config.JwksReadFailed("C:/secure/idp.jwks.json", "access_denied")),
  )
}

pub fn environment_loader_accepts_inline_jwks_with_explicit_provider_test() {
  let source = valid_source() |> dict.insert("team", "true")
  let assert Ok(Some(loaded)) =
    team_config.load_if_requested_with(source, fn(_) {
      Error("inline_jwks_must_not_read_a_file")
    })
  loaded.jwks_json |> should.equal(v2_fixture.public_jwks)
}

pub fn environment_loader_rejects_ambiguous_team_mode_test() {
  team_config.load_if_requested_with(
    dict.from_list([#("team", "sometimes")]),
    fn(_) { Error("unexpected") },
  )
  |> should.equal(Error(team_config.InvalidValue("team")))
}

pub fn environment_loader_discovers_standard_provider_metadata_before_bind_test() {
  let source =
    valid_source()
    |> dict.delete("oidc_authorization_endpoint")
    |> dict.delete("oidc_token_endpoint")
    |> dict.delete("oidc_jwks_json")
    |> dict.insert("team", "true")
  let provider =
    oidc_discovery.ProviderMetadata(
      "https://id.example",
      "https://id.example/authorize",
      "https://id.example/token",
      "https://id.example/jwks",
      v2_fixture.public_jwks,
    )
  let assert Ok(Some(config)) =
    team_config.load_if_requested_with_discovery(
      source,
      fn(_) { Error("offline_file_not_expected") },
      fn(requested_issuer) {
        requested_issuer |> should.equal("https://id.example")
        Ok(provider)
      },
    )
  config.authorization_endpoint
  |> should.equal(provider.authorization_endpoint)
  config.token_endpoint |> should.equal(provider.token_endpoint)
  config.jwks_json |> should.equal(provider.jwks_json)

  team_config.load_if_requested_with_discovery(
    source,
    fn(_) { Error("offline_file_not_expected") },
    fn(_) { Error(oidc_discovery.IssuerMismatch) },
  )
  |> should.equal(
    Error(team_config.DiscoveryFailed(oidc_discovery.IssuerMismatch)),
  )
}

pub fn team_relay_quota_must_be_positive_and_bounded_test() {
  valid_source()
  |> dict.insert("relay_max_events", "0")
  |> team_config.resolve
  |> should.equal(Error(team_config.InvalidInteger("relay_max_events", "0")))

  valid_source()
  |> dict.insert("relay_max_bytes", "1000000000001")
  |> team_config.resolve
  |> should.equal(
    Error(team_config.InvalidInteger("relay_max_bytes", "1000000000001")),
  )
}

pub fn raw_retention_cannot_outlive_metadata_retention_test() {
  valid_source()
  |> dict.insert("retention_days", "7")
  |> dict.insert("raw_retention_days", "8")
  |> team_config.resolve
  |> should.equal(Error(team_config.InvalidValue("raw_retention_days")))

  let assert Ok(config) =
    valid_source()
    |> dict.insert("retention_days", "7")
    |> dict.insert("raw_retention_days", "7")
    |> team_config.resolve
  config.raw_retention_days |> should.equal(7)
}

fn valid_source() {
  dict.from_list([
    #("origin", "https://hub.example"),
    #("oidc_authorization_endpoint", "https://id.example/authorize"),
    #("oidc_token_endpoint", "https://id.example/token"),
    #("oidc_issuer", "https://id.example"),
    #("oidc_client_id", "beamtrace"),
    #("oidc_redirect_uri", "https://hub.example/auth/oidc/callback"),
    #("oidc_jwks_json", v2_fixture.public_jwks),
    #(
      "oidc_group_roles",
      "beam-admins:admin,beam-investigators:investigator,beam-viewers:viewer,beam-raw:raw",
    ),
    #("project", "shop"),
    #("environment", "prod"),
    #("data_dir", "beamtrace-data"),
  ])
}
