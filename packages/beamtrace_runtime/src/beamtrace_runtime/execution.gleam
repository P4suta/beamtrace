// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/cli
import gleam/option.{type Option}

/// Security-relevant execution boundary selected from a parsed command.
pub type Plan {
  TargetDistribution(node: String, cookie_file: Option(String))
  OfflineFiles(paths: List(String))
  HubWithoutCookie
  OutboundRelayOnly(hub_url: String)
  ChildProcess(command: List(String))
  RecordTargetAndChild(
    node: String,
    cookie_file: Option(String),
    command: List(String),
  )
  TuiClient(server: Option(String))
  Diagnostic
  ReadOnlyMcp
  Documentation
}

pub fn plan(command: cli.Command) -> Plan {
  case command {
    cli.Attach(node, _, cookie_file) -> TargetDistribution(node, cookie_file)
    cli.Capture(node, _, _, _, cookie_file, _, _) ->
      TargetDistribution(node, cookie_file)
    cli.Record(node, _, _, _, cookie_file, _, _, command) ->
      RecordTargetAndChild(node, cookie_file, command)
    cli.Open(path, _) -> OfflineFiles([path])
    cli.Compare(left, right) -> OfflineFiles([left, right])
    cli.Export(path, _) -> OfflineFiles([path])
    cli.Serve -> HubWithoutCookie
    cli.Relay(hub_url, _, _) -> OutboundRelayOnly(hub_url)
    cli.Tui(server) -> TuiClient(server)
    cli.Doctor -> Diagnostic
    cli.Mcp -> ReadOnlyMcp
    cli.Help | cli.Version -> Documentation
  }
}
