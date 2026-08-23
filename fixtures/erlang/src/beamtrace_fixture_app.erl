%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_fixture_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Arguments) -> beamtrace_fixture_sup:start_link().
stop(_State) -> ok.
