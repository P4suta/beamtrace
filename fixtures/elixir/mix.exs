# SPDX-License-Identifier: Apache-2.0 OR MIT
defmodule BeamTraceElixirFixture.MixProject do
  use Mix.Project

  def project, do: [app: :beamtrace_elixir_fixture, version: "0.1.0", elixir: "~> 1.17"]
  def application, do: [extra_applications: [:logger], mod: {BeamTraceFixture.Application, []}]
end
