%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_demo_fixture).
-export([run/0, run_gleam/0]).

run_gleam() ->
    %% Keep the demo trigger as an external MFA call. A direct local call is
    %% compiled to a local BEAM instruction and does not cross the public
    %% trace-pattern boundary that `record --trigger ...` arms.
    erlang:apply(?MODULE, run, []),
    nil.

run() ->
    Parent = self(),
    Worker = spawn(fun() -> demo_worker(Parent) end),
    Worker ! {checkout, 42, [apple, coffee]},
    receive
        {checked_out, 42, Total} ->
            io:format("BeamTrace demo checkout total: ~B~n", [Total])
    after 5000 ->
        erlang:error(demo_timeout)
    end.

demo_worker(Parent) ->
    receive
        {checkout, OrderId, Items} ->
            Parent ! {checked_out, OrderId, length(Items) * 1250}
    end.
