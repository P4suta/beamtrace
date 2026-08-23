%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_fixture_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => leaf, start => {beamtrace_fixture_leaf, start_link, []}},
        #{id => worker, start => {beamtrace_fixture_worker, start_link, []}}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
