// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_runtime/credit_policy
import beamtrace_runtime/enrollment_store
import beamtrace_runtime/relay_inbox
import beamtrace_runtime/relay_payload
import beamtrace_runtime/relay_session
import beamtrace_runtime/relay_wire
import gleam/int
import gleam/option.{type Option, None, Some}

const hello_timeout_ms = 10_000

const heartbeat_timeout_ms = 30_000

pub type SessionState {
  SessionState(start: relay_session.Start, last_sequence: Int)
}

pub type State {
  AwaitingHello(
    store: enrollment_store.Store,
    expected_relay_id: String,
    connected_at_ms: Int,
  )
  Active(
    relay: enrollment_store.RelayRecord,
    protocol_version: Int,
    last_sequence: Int,
    last_heartbeat_ms: Int,
    credits_remaining: Int,
    session: Option(SessionState),
  )
  Rejected(reason: String)
}

pub type Effect {
  SendText(frame: String)
  SessionStarted(start: relay_session.Start)
  Payload(
    session_id: String,
    relay_id: String,
    sequence: Int,
    mode: relay_inbox.Mode,
    payload: String,
  )
  SessionEnded(end: relay_session.End)
  Close(reason: String)
}

pub type Transition {
  Transition(state: State, effects: List(Effect))
}

pub fn new(
  store: enrollment_store.Store,
  expected_relay_id: String,
  now_ms: Int,
) -> State {
  AwaitingHello(store, expected_relay_id, now_ms)
}

pub fn receive_text(state: State, frame: String, now_ms: Int) -> Transition {
  case state {
    AwaitingHello(store, expected_relay_id, _) ->
      receive_hello(store, expected_relay_id, frame, now_ms)
    Active(relay, protocol_version, previous_sequence, _, credits, session) ->
      receive_envelope(
        relay,
        protocol_version,
        previous_sequence,
        credits,
        session,
        frame,
        now_ms,
      )
    Rejected(reason) -> Transition(state, [Close(reason)])
  }
}

pub fn expire(state: State, now_ms: Int) -> State {
  case state {
    AwaitingHello(_, _, connected_at)
      if now_ms - connected_at > hello_timeout_ms
    -> Rejected("hello_timeout")
    Active(_, _, _, last_heartbeat, _, _)
      if now_ms - last_heartbeat > heartbeat_timeout_ms
    -> Rejected("heartbeat_timeout")
    _ -> state
  }
}

fn receive_hello(
  store: enrollment_store.Store,
  expected_relay_id: String,
  frame: String,
  now_ms: Int,
) -> Transition {
  case relay_wire.decode_hello(frame) {
    Error(reason) -> reject(reason)
    Ok(hello) ->
      case hello.relay_id == expected_relay_id {
        False -> reject("relay_id_mismatch")
        True ->
          case relay_wire.authenticate(store, hello, now_ms) {
            Error(reason) -> reject(reason)
            Ok(relay) ->
              Transition(
                Active(
                  relay,
                  hello.protocol_version,
                  0,
                  now_ms,
                  credit_policy.initial_credits,
                  None,
                ),
                [
                  SendText(credit_frame(
                    hello.protocol_version,
                    credit_policy.initial_credits,
                  )),
                ],
              )
          }
      }
  }
}

fn receive_envelope(
  relay: enrollment_store.RelayRecord,
  protocol_version: Int,
  previous_sequence: Int,
  credits: Int,
  session: Option(SessionState),
  frame: String,
  now_ms: Int,
) -> Transition {
  case relay_wire.decode_envelope(frame) {
    Error(reason) -> reject(reason)
    Ok(envelope) if envelope.protocol_version != protocol_version ->
      reject("protocol_version_changed")
    Ok(envelope) ->
      case
        relay_wire.verify_envelope(
          relay.public_key,
          envelope,
          previous_sequence,
        )
      {
        Error(reason) -> reject(reason)
        Ok(payload) ->
          case relay_session.decode_message(payload) {
            Error(reason) -> reject(reason)
            Ok(relay_session.Heartbeat) ->
              Transition(
                Active(
                  relay,
                  protocol_version,
                  envelope.sequence,
                  now_ms,
                  credits,
                  session,
                ),
                [],
              )
            Ok(relay_session.SessionStart(start)) ->
              receive_session_start(
                relay,
                protocol_version,
                envelope.sequence,
                start,
                now_ms,
                session,
              )
            Ok(relay_session.Batch(_, _, _, _)) if credits <= 0 ->
              reject("awaiting_credit")
            Ok(relay_session.Batch(
              session_id,
              session_sequence,
              inner_payload,
              batch,
            )) ->
              receive_session_batch(
                relay,
                protocol_version,
                envelope.sequence,
                credits,
                session,
                session_id,
                session_sequence,
                inner_payload,
                batch,
                now_ms,
              )
            Ok(relay_session.SessionEnd(end)) ->
              receive_session_end(
                relay,
                protocol_version,
                envelope.sequence,
                credits,
                session,
                end,
                now_ms,
              )
          }
      }
  }
}

fn receive_session_start(
  relay: enrollment_store.RelayRecord,
  protocol_version: Int,
  sequence: Int,
  start: relay_session.Start,
  now_ms: Int,
  current: Option(SessionState),
) -> Transition {
  case current, start.relay_id == relay.id {
    Some(_), _ -> reject("session_already_active")
    _, False -> reject("session_relay_mismatch")
    None, True ->
      Transition(
        Active(
          relay,
          protocol_version,
          sequence,
          now_ms,
          credit_policy.initial_credits,
          Some(SessionState(start, 0)),
        ),
        [SessionStarted(start)],
      )
  }
}

fn receive_session_batch(
  relay: enrollment_store.RelayRecord,
  protocol_version: Int,
  sequence: Int,
  credits: Int,
  current: Option(SessionState),
  session_id: String,
  session_sequence: Int,
  payload: String,
  batch: relay_payload.Batch,
  now_ms: Int,
) -> Transition {
  case current {
    None -> reject("session_required")
    Some(SessionState(start, previous_session_sequence)) ->
      case
        start.session_id == session_id,
        session_sequence == previous_session_sequence + 1,
        relay_session.mode_name(start.mode) == batch.mode,
        relay_session.privacy_name(start.privacy) == batch_privacy(batch),
        batch.event_count > 0
      {
        False, _, _, _, _ -> reject("session_id_mismatch")
        _, False, _, _, _ -> reject("invalid_session_sequence")
        _, _, False, _, _ -> reject("session_mode_mismatch")
        _, _, _, False, _ -> reject("session_privacy_mismatch")
        _, _, _, _, False -> reject("empty_batch")
        True, True, True, True, True -> {
          let mode = case start.mode {
            relay_session.Exact -> relay_inbox.Exact
            relay_session.Live -> relay_inbox.Live
          }
          Transition(
            Active(
              relay,
              protocol_version,
              sequence,
              now_ms,
              credits - 1,
              Some(SessionState(start, session_sequence)),
            ),
            [Payload(session_id, relay.id, session_sequence, mode, payload)],
          )
        }
      }
  }
}

fn receive_session_end(
  relay: enrollment_store.RelayRecord,
  protocol_version: Int,
  sequence: Int,
  credits: Int,
  current: Option(SessionState),
  end: relay_session.End,
  now_ms: Int,
) -> Transition {
  case current {
    None -> reject("session_required")
    Some(SessionState(start, previous_session_sequence)) ->
      case
        start.session_id == end.session_id,
        end.sequence == previous_session_sequence + 1
      {
        False, _ -> reject("session_id_mismatch")
        _, False -> reject("invalid_session_sequence")
        True, True ->
          Transition(
            Active(relay, protocol_version, sequence, now_ms, credits, None),
            [
              SessionEnded(end),
            ],
          )
      }
  }
}

fn reject(reason: String) -> Transition {
  Transition(Rejected(reason), [Close(reason)])
}

pub fn durable_accept(state: State) -> #(State, Option(String)) {
  case state {
    Active(relay, protocol_version, sequence, heartbeat, remaining, session) -> {
      let refill = credit_policy.after_durable_accept(remaining)
      case refill.granted {
        0 -> #(state, None)
        granted -> #(
          Active(
            relay,
            protocol_version,
            sequence,
            heartbeat,
            refill.available,
            session,
          ),
          Some(credit_frame(protocol_version, granted)),
        )
      }
    }
    _ -> #(state, None)
  }
}

pub fn current_session(state: State) -> Option(#(String, String)) {
  case state {
    Active(relay, _, _, _, _, Some(SessionState(session, _))) ->
      Some(#(session.session_id, relay.id))
    _ -> None
  }
}

pub fn negotiated_protocol_version(state: State) -> Int {
  case state {
    Active(_, version, _, _, _, _) -> version
    _ -> relay_wire.protocol_version
  }
}

fn credit_frame(protocol_version: Int, credits: Int) -> String {
  "{\"type\":\"credit\",\"protocol_version\":"
  <> int.to_string(protocol_version)
  <> ",\"credits\":"
  <> int.to_string(credits)
  <> ",\"max_batch_events\":128}"
}

fn batch_privacy(batch: relay_payload.Batch) -> String {
  case batch.privacy {
    relay_payload.MetadataBatch -> "metadata"
    relay_payload.RawBatch(_, _) -> "raw"
  }
}
