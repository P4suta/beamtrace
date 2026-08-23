# SPDX-License-Identifier: Apache-2.0 OR MIT
defmodule BeamTraceFixture.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [BeamTraceFixture.Leaf, BeamTraceFixture.Worker]
    Supervisor.start_link(children, strategy: :one_for_one, name: BeamTraceFixture.Supervisor)
  end
end
