// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/blob_store
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/local_auth
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_ingest
import beamtrace_runtime/relay_socket
import beamtrace_runtime/team_store
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{Some}
import mist

type Tick {
  Tick
}

type WebsocketState {
  WebsocketState(protocol: relay_socket.State, tick: process.Subject(Tick))
}

pub fn upgrade(
  request: Request(mist.Connection),
  enrollment: enrollment_store.Store,
  inbox: relay_inbox.Store,
  metadata: team_store.Store,
  backend: blob_store.Backend,
  quota: relay_ingest.Quota,
  relay_id: String,
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
        ),
        Some(selector),
      )
    },
    on_close: fn(_state) { Nil },
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
  let WebsocketState(protocol, tick) = state
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
          mist.continue(WebsocketState(next_protocol, tick))
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
  connection: mist.WebsocketConnection,
) -> mist.Next(WebsocketState, Tick) {
  case effects {
    [] -> mist.continue(WebsocketState(protocol, tick))
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
                connection,
              )
            Error(_) -> mist.stop_abnormal("relay_send_failed")
          }
        relay_socket.Payload(relay_id, sequence, mode, payload) -> {
          let received_at_ms = local_auth.now_ms()
          case
            relay_ingest.accept_with_backend_quota(
              metadata,
              backend,
              inbox,
              relay_id,
              sequence,
              mode,
              payload,
              received_at_ms,
              quota,
            )
          {
            Ok(relay_inbox.Accepted) as accepted ->
              case
                mist.send_text_frame(connection, ingest_control_frame(accepted))
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
                    connection,
                  )
              }
            Ok(relay_inbox.Truncated(_)) as truncated -> {
              let _ =
                mist.send_text_frame(
                  connection,
                  ingest_control_frame(truncated),
                )
              mist.stop()
            }
            Error(_) as failed -> {
              let _ =
                mist.send_text_frame(connection, ingest_control_frame(failed))
              mist.stop()
            }
          }
        }
        relay_socket.Close(_) -> mist.stop_abnormal("relay_protocol_error")
      }
  }
}

pub fn ingest_control_frame(
  outcome: Result(relay_inbox.AppendStatus, String),
) -> String {
  case outcome {
    Ok(relay_inbox.Accepted) ->
      "{\"type\":\"credit\",\"protocol_version\":1,\"credits\":1,\"max_batch_events\":128}"
    Ok(relay_inbox.Truncated(_)) -> truncated_frame()
    Error("relay_event_quota")
    | Error("relay_byte_quota")
    | Error("batch_event_limit") -> stop_frame("hub_quota")
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
    | Error("raw_item_limit") -> stop_frame("privacy_policy")
    Error("invalid_payload") -> stop_frame("relay_protocol")
    Error(_) -> storage_error_frame()
  }
}

fn truncated_frame() -> String {
  "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\"hub_inbox_budget\"}"
}

fn storage_error_frame() -> String {
  stop_frame("hub_storage_error")
}

fn stop_frame(reason: String) -> String {
  "{\"type\":\"stop\",\"completeness\":\"truncated\",\"reason\":\""
  <> reason
  <> "\"}"
}
