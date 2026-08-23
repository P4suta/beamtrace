// SPDX-License-Identifier: Apache-2.0 OR MIT
import beamtrace_fixture/leaf
import beamtrace_fixture/worker
import gleam/erlang/process.{type Name}
import gleam/otp/actor.{type Started}
import gleam/otp/static_supervisor.{type Supervisor} as supervisor

pub type Runtime {
  Runtime(supervisor: Started(Supervisor), worker_name: Name(worker.Message))
}

pub fn start() {
  let leaf_name = process.new_name(prefix: "beamtrace_fixture_leaf")
  let worker_name = process.new_name(prefix: "beamtrace_fixture_worker")
  case
    supervisor.new(supervisor.OneForOne)
    |> supervisor.restart_tolerance(intensity: 5, period: 10)
    |> supervisor.add(leaf.supervised(leaf_name))
    |> supervisor.add(worker.supervised(worker_name, leaf_name))
    |> supervisor.start
  {
    Ok(started) -> Ok(Runtime(started, worker_name))
    Error(error) -> Error(error)
  }
}

pub fn operation(runtime: Runtime, value: Int) -> Int {
  process.call(
    process.named_subject(runtime.worker_name),
    waiting: 1000,
    sending: fn(reply) { worker.Operation(value, reply) },
  )
}

pub fn bump(runtime: Runtime) -> Nil {
  process.send(process.named_subject(runtime.worker_name), worker.Bump)
}

pub fn crash(runtime: Runtime) -> Nil {
  process.send(process.named_subject(runtime.worker_name), worker.Crash)
}

pub fn main() {
  let assert Ok(_runtime) = start()
  process.sleep_forever()
}
