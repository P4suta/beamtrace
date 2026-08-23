# SPDX-License-Identifier: Apache-2.0 OR MIT
defmodule BeamTraceFixtureTest do
  use ExUnit.Case, async: false

  test "call chain and supervisor restart" do
    assert BeamTraceFixture.Worker.operation(21) == 42
    before = Process.whereis(BeamTraceFixture.Worker)
    catch_exit(BeamTraceFixture.Worker.crash())
    after_pid = wait_for_restart(before, 100)
    refute before == after_pid
    assert BeamTraceFixture.Worker.operation(5) == 10
  end

  defp wait_for_restart(_before, 0), do: flunk("restart timeout")
  defp wait_for_restart(before, attempts) do
    case Process.whereis(BeamTraceFixture.Worker) do
      pid when is_pid(pid) and pid != before -> pid
      _ -> Process.sleep(10); wait_for_restart(before, attempts - 1)
    end
  end
end
