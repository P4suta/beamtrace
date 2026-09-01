// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/local_auth
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_ingest
import beamtrace_runtime/relay_session
import beamtrace_runtime/relay_socket
import beamtrace_runtime/relay_wire
import beamtrace_runtime/team_store
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{type Option, None, Some}
import mist

type Tick {
  Tick
}

type WebsocketState {
  WebsocketState(
    protocol: relay_socket.State,
    tick: process.Subject(Tick),
    project: String,
    environment: String,
    persisted_session: Option(#(String, String)),
  )
}

pub fn upgrade(
  request: Request(mist.Connection),
  enrollment: enrollment_store.Store,
  inbox: relay_inbox.Store,
  metadata: team_store.Store,
  backend: blob_store.Backend,
  quota: relay_ingest.Quota,
  relay_id: String,
  project: String,
  environment: String,
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: request,
    on_init: fn(_connection) {
      let tick = process.new_subject()
      let _timer = process.send_after(tick, 1000, Tick)
      let selector = process.select(process.new_selector(), for: tick)
      #(
        WebsocketState(
          relay_socket.new(enrollment, relay_id, local_auth.now_ms()),
          tick,
          project,
          environment,
          None,
        ),
        Some(selector),
      )
    },
    on_close: fn(state) {
      let WebsocketState(_, _, _, _, persisted_session) = state
      case persisted_session {
        None -> Nil
        Some(#(session_id, active_relay_id)) -> {
          let _ =
            team_store.mark_trace_failed(
              metadata,
              session_id,
              active_relay_id,
              local_auth.now_ms(),
            )
          Nil
        }
      }
    },
    handler: fn(state, message, connection) {
      handle_message(
        inbox,
        metadata,
        backend,
        quota,
        state,
        message,
        connection,
      )
    },
  )
}

fn handle_message(
  inbox: relay_inbox.Store,
  metadata: team_store.Store,
  backend: blob_store.Backend,
  quota: relay_ingest.Quota,
  state: WebsocketState,
  message: mist.WebsocketMessage(Tick),
  connection: mist.WebsocketConnection,
) -> mist.Next(WebsocketState, Tick) {
  let WebsocketState(protocol, tick, project, environment, persisted_session) =
    state
  case message {
    mist.Text(frame) -> {
      let transition =
        relay_socket.receive_text(protocol, frame, local_auth.now_ms())
      apply_effects(
        inbox,
        metadata,
        backend,
        quota,
        transition.effects,
        transition.state,
        tick,
        project,
        environment,
        persisted_session,
        connection,
      )
    }
    mist.Binary(_) -> mist.stop_abnormal("binary_frames_not_supported")
    mist.Custom(Tick) -> {
      let next_protocol = relay_socket.expire(protocol, local_auth.now_ms())
      case next_protocol {
        relay_socket.Rejected(_) -> mist.stop_abnormal("relay_timeout")
        _ -> {
          let _timer = process.send_after(tick, 1000, Tick)
          mist.continue(WebsocketState(
            next_protocol,
            tick,
            project,
            environment,
            persisted_session,
          ))
        }
      }
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn apply_effects(
  inbox: relay_inbox.Store,
  metadata: team_store.Store,
  backend: blob_store.Backend,
  quota: relay_ingest.Quota,
  effects: List(relay_socket.Effect),
  protocol: relay_socket.State,
  tick: process.Subject(Tick),
  project: String,
  environment: String,
  persisted_session: Option(#(String, String)),
  connection: mist.WebsocketConnection,
) -> mist.Next(WebsocketState, Tick) {
  case effects {
    [] ->
      mist.continue(WebsocketState(
        protocol,
        tick,
        project,
        environment,
        persisted_session,
      ))
    [effect, ..rest] ->
      case effect {
        relay_socket.SendText(frame) ->
          case mist.send_text_frame(connection, frame) {
            Ok(Nil) ->
              apply_effects(
                inbox,
                metadata,
                backend,
                quota,
                rest,
                protocol,
                tick,
                project,
                environment,
                persisted_session,
                connection,
              )
            Error(_) -> mist.stop_abnormal("relay_send_failed")
          }
        relay_socket.SessionStarted(start) -> {
          let received_at_ms = local_auth.now_ms()
          let session =
            team_store.TraceSession(
              id: start.session_id,
              relay_id: start.relay_id,
              project: project,
              environment: environment,
              node: start.node,
              module: start.module,
              function: start.function,
              arity: start.arity,
              mode: relay_session.mode_name(start.mode),
              privacy: relay_session.privacy_name(start.privacy),
              started_at_ms: start.started_at_ms,
              received_at_ms: received_at_ms,
              ended_at_ms: 0,
              last_received_at_ms: received_at_ms,
              delivery_status: "active",
              event_count: 0,
              legal_hold: False,
              active: True,
            )
          case team_store.begin_trace_session(metadata, session, 64) {
            Error(_) -> {
              let _ =
                mist.send_text_frame(
                  connection,
                  stop_frame_for(
                    relay_socket.negotiated_protocol_version(protocol),
                    "session_rejected",
                  ),
                )
              mist.stop()
            }
            Ok(_) ->
              apply_effects(
                inbox,
                metadata,
                backend,
                quota,
                rest,
                protocol,
                tick,
                project,
                environment,
                Some(#(start.session_id, start.relay_id)),
                connection,
              )
          }
        }
        relay_socket.Payload(session_id, relay_id, sequence, mode, payload) -> {
          let received_at_ms = local_auth.now_ms()
          case
            relay_ingest.accept_session_with_backend_quota(
              metadata,
              backend,
              inbox,
              session_id,
              relay_id,
              sequence,
              mode,
              payload,
              received_at_ms,
              quota,
            )
          {
            Ok(relay_inbox.Accepted) -> {
              let #(next_protocol, credit) =
                relay_socket.durable_accept(protocol)
              case credit {
                None ->
                  apply_effects(
                    inbox,
                    metadata,
                    backend,
                    quota,
                    rest,
                    next_protocol,
                    tick,
                    project,
                    environment,
                    persisted_session,
                    connection,
                  )
                Some(frame) ->
                  case mist.send_text_frame(connection, frame) {
                    Error(_) -> mist.stop_abnormal("relay_send_failed")
                    Ok(Nil) ->
                      apply_effects(
                        inbox,
                        metadata,
                        backend,
                        quota,
                        rest,
                        next_protocol,
                        tick,
                        project,
                        environment,
                        persisted_session,
                        connection,
                      )
                  }
              }
            }
            Ok(relay_inbox.Truncated(_)) as truncated -> {
              let _ =
                mist.send_text_frame(
                  connection,
                  ingest_control_frame_for(
                    relay_socket.negotiated_protocol_version(protocol),
                    truncated,
                  ),
                )
              mist.stop()
            }
            Error(_) as failed -> {
              let _ =
                mist.send_text_frame(
                  connection,
                  ingest_control_frame_for(
                    relay_socket.negotiated_protocol_version(protocol),
                    failed,
                  ),
                )
              mist.stop()
            }
          }
        }
        relay_socket.SessionEnded(end) -> {
          let relay_id = case protocol {
            relay_socket.Active(relay, _, _, _, _, _) -> relay.id
            _ -> ""
          }
          case
            team_store.finish_trace_session(
              metadata,
              end.session_id,
              relay_id,
              relay_session.delivery_status_name(end.delivery_status),
              end.ended_at_ms,
              local_auth.now_ms(),
            )
          {
            Error(_) -> mist.stop_abnormal("session_end_failed")
            Ok(_) ->
              case
                mist.send_text_frame(
                  connection,
                  session_ack_frame_for(
                    relay_socket.negotiated_protocol_version(protocol),
                    end,
                  ),
                )
              {
                Error(_) -> mist.stop_abnormal("relay_send_failed")
                Ok(Nil) ->
                  apply_effects(
                    inbox,
                    metadata,
                    backend,
                    quota,
                    rest,
                    protocol,
                    tick,
                    project,
                    environment,
                    None,
                    connection,
                  )
              }
          }
        }
        relay_socket.Close(_) -> mist.stop_abnormal("relay_protocol_error")
      }
  }
}

pub fn session_ack_frame(end: relay_session.End) -> String {
  session_ack_frame_for(relay_wire_protocol_version(), end)
}

fn session_ack_frame_for(
  protocol_version: Int,
  end: relay_session.End,
) -> String {
  let status = relay_session.delivery_status_name(end.delivery_status)
  let status_field = case protocol_version {
    2 -> #("completeness", json.string(legacy_delivery_status(status)))
    _ -> #("delivery_status", json.string(status))
  }
  json.object([
    #("type", json.string("session_ack")),
    #("protocol_version", json.int(protocol_version)),
    #("session_id", json.string(end.session_id)),
    #("sequence", json.int(end.sequence)),
    status_field,
  ])
  |> json.to_string
}

pub fn ingest_control_frame(
  outcome: Result(relay_inbox.AppendStatus, String),
) -> String {
  ingest_control_frame_for(relay_wire_protocol_version(), outcome)
}

fn ingest_control_frame_for(
  protocol_version: Int,
  outcome: Result(relay_inbox.AppendStatus, String),
) -> String {
  case outcome {
    Ok(relay_inbox.Accepted) -> ""
    Ok(relay_inbox.Truncated(_)) -> truncated_frame_for(protocol_version)
    Error("relay_event_quota")
    | Error("relay_byte_quota")
    | Error("session_event_quota")
    | Error("session_byte_quota")
    | Error("batch_event_limit") ->
      stop_frame_for(protocol_version, "hub_quota")
    Error("metadata_value_forbidden")
    | Error("invalid_metadata_fingerprint")
    | Error("raw_capture_not_authorized")
    | Error("invalid_raw_capture_grant")
    | Error("raw_capture_grant_denied")
    | Error("invalid_raw_policy")
    | Error("invalid_raw_value")
    | Error("raw_value_required")
    | Error("raw_redaction_required")
    | Error("raw_depth_exceeded")
    | Error("raw_item_limit") ->
      stop_frame_for(protocol_version, "privacy_policy")
    Error("invalid_payload")
    | Error("unknown_session")
    | Error("session_not_active")
    | Error("session_relay_mismatch")
    | Error("session_mode_mismatch")
    | Error("session_privacy_mismatch")
    | Error("empty_batch") -> stop_frame_for(protocol_version, "relay_protocol")
    Error(_) -> storage_error_frame_for(protocol_version)
  }
}

fn truncated_frame_for(protocol_version: Int) -> String {
  stop_frame_for(protocol_version, "hub_inbox_budget")
}

fn storage_error_frame_for(protocol_version: Int) -> String {
  stop_frame_for(protocol_version, "hub_storage_error")
}

fn stop_frame_for(protocol_version: Int, reason: String) -> String {
  case protocol_version {
    2 ->
      "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\""
      <> reason
      <> "\"}"
    _ ->
      json.object([
        #("type", json.string("stop")),
        #("protocol_version", json.int(protocol_version)),
        #("delivery_status", json.string("partial")),
        #("reason", json.string(reason)),
      ])
      |> json.to_string
  }
}

fn legacy_delivery_status(status: String) -> String {
  case status {
    "delivered" -> "complete"
    "partial" -> "truncated"
    _ -> "incomplete"
  }
}

fn relay_wire_protocol_version() -> Int {
  relay_wire.protocol_version
}
