%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_fixture_leaf).
-behaviour(gen_server).
-export([start_link/0, double/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
double(Value) -> gen_server:call(?MODULE, {double, Value}).
init([]) -> {ok, #{}}.
handle_call({double, Value}, _From, State) -> {reply, Value * 2, State}.
handle_cast(_Message, State) -> {noreply, State}.
