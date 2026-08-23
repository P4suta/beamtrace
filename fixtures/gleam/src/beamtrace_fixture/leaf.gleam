// SPDX-License-Identifier: Apache-2.0 OR MIT
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision

pub type Message {
  Double(value: Int, reply: Subject(Int))
}

pub fn start(name: Name(Message)) {
  actor.new(Nil)
  |> actor.named(name)
  |> actor.on_message(fn(state, message) {
    let Double(value, reply) = message
    process.send(reply, value * 2)
    actor.continue(state)
  })
  |> actor.start
}

pub fn supervised(name: Name(Message)) {
  supervision.worker(run: fn() { start(name) })
}
