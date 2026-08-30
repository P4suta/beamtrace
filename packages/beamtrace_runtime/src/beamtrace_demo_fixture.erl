%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_demo_fixture).
-export([run/0, run_gleam/0]).

run_gleam() ->
    %% Keep the demo trigger as an external MFA call. A direct local call is
    %% compiled to a local BEAM instruction and does not cross the public
    %% trace-pattern boundary that `record --trigger ...` arms.
    erlang:apply(?MODULE, run, []),
    nil.

%% A checkout asks inventory to reserve the items, then payment to charge the
%% total, and reports the total. Every actor carries a process label so the
%% causal lanes read as roles rather than pids.
run() ->
    put('$process_label', checkout),
    Checkout = self(),
    Inventory = spawn(fun() -> actor(inventory, Checkout) end),
    Payment = spawn(fun() -> actor(payment, Checkout) end),
    Inventory ! {reserve, 42, [apple, coffee]},
    Total = receive
        {reserved, 42, Count} -> Count * 1250
    after 5000 ->
        erlang:error(demo_timeout)
    end,
    Payment ! {charge, 42, Total},
    receive
        {charged, 42, Total} ->
            io:format("BeamTrace demo checkout total: ~B~n", [Total])
    after 5000 ->
        erlang:error(demo_timeout)
    end.

actor(Role, Checkout) ->
    put('$process_label', Role),
    register(Role, self()),
    receive
        {reserve, OrderId, Items} ->
            Checkout ! {reserved, OrderId, length(Items)};
        {charge, OrderId, Total} ->
            Checkout ! {charged, OrderId, Total}
    end,
    %% Stay observable until the VM stops so the agent can read the label
    %% after the reply; the recorded operation itself already completed.
    receive stop -> ok after 5000 -> ok end.
