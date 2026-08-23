// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/rbac
import beamtrace_runtime/team_config
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

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
  config.relay_max_events |> should.equal(1_000_000)
  config.relay_max_bytes |> should.equal(1_073_741_824)
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
      Ok("{\"keys\":[]}")
    })
  loaded.jwks_json |> should.equal("{\"keys\":[]}")

  team_config.load_if_requested_with(source, fn(_) { Error("access_denied") })
  |> should.equal(
    Error(team_config.JwksReadFailed("C:/secure/idp.jwks.json", "access_denied")),
  )
}

pub fn environment_loader_rejects_ambiguous_team_mode_test() {
  team_config.load_if_requested_with(
    dict.from_list([#("team", "sometimes")]),
    fn(_) { Error("unexpected") },
  )
  |> should.equal(Error(team_config.InvalidValue("team")))
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

fn valid_source() {
  dict.from_list([
    #("origin", "https://hub.example"),
    #("oidc_authorization_endpoint", "https://id.example/authorize"),
    #("oidc_token_endpoint", "https://id.example/token"),
    #("oidc_issuer", "https://id.example"),
    #("oidc_client_id", "beamtrace"),
    #("oidc_redirect_uri", "https://hub.example/auth/oidc/callback"),
    #("oidc_jwks_json", "{\"keys\":[]}"),
    #(
      "oidc_group_roles",
      "beam-admins:admin,beam-investigators:investigator,beam-viewers:viewer,beam-raw:raw",
    ),
    #("project", "shop"),
    #("environment", "prod"),
    #("data_dir", "beamtrace-data"),
  ])
}
