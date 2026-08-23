# SPDX-License-Identifier: Apache-2.0 OR MIT
defmodule BeamTraceFixture.Leaf do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def double(value), do: GenServer.call(__MODULE__, {:double, value})
  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_call({:double, value}, _from, state), do: {:reply, value * 2, state}
end
