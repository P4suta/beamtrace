# SPDX-License-Identifier: Apache-2.0 OR MIT
defmodule BeamTraceFixture.Worker do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{bumps: 0}, name: __MODULE__)
  def operation(value), do: GenServer.call(__MODULE__, {:operation, value})
  def crash, do: GenServer.call(__MODULE__, :crash)
  def bump, do: GenServer.cast(__MODULE__, :bump)
  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_call({:operation, value}, _from, state), do: {:reply, BeamTraceFixture.Leaf.double(value), state}
  @impl true
  def handle_call(:crash, _from, _state), do: raise("intentional fixture crash")
  @impl true
  def handle_cast(:bump, state), do: {:noreply, Map.update!(state, :bumps, &(&1 + 1))}
end
