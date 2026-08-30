//// Classify privacy-safe term views into small semantic protocol labels.
////
//// Classification uses only already-redacted structure, is total, performs no
//// I/O, and is O(size of the bounded view). It produces the same labels on
//// Erlang and JavaScript.

// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace/types

/// A conservative label for recognizable BEAM protocol message shapes.
pub type SemanticMessage {
  Call
  Cast
  Reply
  MonitorDown
  ExitSignal
  Timeout
  SpawnProtocol
  Ordinary
}

/// Classifies only shapes with protocol evidence. Ambiguous tuples stay
/// Ordinary rather than being presented as a semantic call or reply.
pub fn classify(message: types.TermView) -> SemanticMessage {
  case message {
    types.Constructor("$gen_call", _) -> Call
    types.Constructor("$gen_cast", _) -> Cast
    types.Constructor("$gen_reply", _) -> Reply
    types.Constructor("spawn_request", _) -> SpawnProtocol
    types.Tuple([types.Atom("$gen_call"), _, _]) -> Call
    types.Tuple([types.Atom("$gen_cast"), _]) -> Cast
    types.Tuple([types.Atom("$gen_reply"), _, _]) -> Reply
    types.Tuple([types.Atom("DOWN"), _, _, _, _]) -> MonitorDown
    types.Tuple([types.Atom("EXIT"), _, _]) -> ExitSignal
    types.Tuple([types.Atom("spawn_request"), _, _, _]) -> SpawnProtocol
    types.Atom("timeout") | types.Tag("timeout") -> Timeout
    _ -> Ordinary
  }
}

/// Return the stable display label for a redacted term view in O(view size).
pub fn label(message: types.TermView) -> String {
  case classify(message) {
    Call -> "call"
    Cast -> "cast"
    Reply -> "reply"
    MonitorDown -> "DOWN"
    ExitSignal -> "EXIT"
    Timeout -> "timeout"
    SpawnProtocol -> "spawn"
    Ordinary -> "message"
  }
}
