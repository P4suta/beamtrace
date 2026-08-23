// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_fixture/leaf
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision

pub type Message {
  Operation(value: Int, reply: Subject(Int))
  Bump
  Crash
}

pub fn start(name: Name(Message), leaf_name: Name(leaf.Message)) {
  actor.new(#(leaf_name, 0))
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn supervised(name: Name(Message), leaf_name: Name(leaf.Message)) {
  supervision.worker(run: fn() { start(name, leaf_name) })
}

fn handle_message(state: #(Name(leaf.Message), Int), message: Message) {
  let #(leaf_name, bumps) = state
  case message {
    Operation(value, reply) -> {
      let result =
        process.call(
          process.named_subject(leaf_name),
          waiting: 1000,
          sending: fn(reply) { leaf.Double(value, reply) },
        )
      process.send(reply, result)
      actor.continue(state)
    }
    Bump -> actor.continue(#(leaf_name, bumps + 1))
    Crash -> actor.stop_abnormal("intentional fixture crash")
  }
}
