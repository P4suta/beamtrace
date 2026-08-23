%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_fixture_worker).
-behaviour(gen_server).
-export([start_link/0, operation/1, crash/0, bump/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
operation(Value) -> gen_server:call(?MODULE, {operation, Value}).
crash() -> gen_server:call(?MODULE, crash).
bump() -> gen_server:cast(?MODULE, bump).

init([]) -> {ok, #{bumps => 0}}.
handle_call({operation, Value}, _From, State) ->
    {reply, beamtrace_fixture_leaf:double(Value), State};
handle_call(crash, _From, _State) -> exit(intentional_fixture_crash).
handle_cast(bump, State) ->
    {noreply, State#{bumps := maps:get(bumps, State) + 1}}.
