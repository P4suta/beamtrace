// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/log
import gleam/list
import gleam/string
import gleeunit/should

pub fn structured_logs_drop_sensitive_fields_in_human_and_json_modes_test() {
  let fields = [
    log.Field("bind", "127.0.0.1:0"),
    log.Field("bootstrap_token", "do-not-log"),
    log.Field("raw_payload", "also-secret"),
    log.Field("oidc_client_secret", "provider-secret"),
  ]
  [log.Human, log.Json]
  |> list.each(fn(format) {
    let rendered = log.render(format, log.Info, "server.ready", fields)
    rendered |> string.contains("127.0.0.1:0") |> should.be_true()
    rendered |> string.contains("do-not-log") |> should.be_false()
    rendered |> string.contains("also-secret") |> should.be_false()
    rendered |> string.contains("provider-secret") |> should.be_false()
  })
}
