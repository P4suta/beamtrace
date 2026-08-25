#!/usr/bin/env escript
%%! +S 4:4 -noshell
%% SPDX-License-Identifier: Apache-2.0 OR MIT

-define(MAX_100K_MS, 60000).
-define(MAX_MEMORY_BYTES, 1073741824).

main([Root, "--one", CountSource]) ->
    ok = add_code_paths(Root),
    {Elapsed, Peak} = measure(list_to_integer(CountSource)),
    io:format("elapsed=~Bms peak=~BMiB~n", [Elapsed, Peak div 1048576]),
    ok;
main([Root]) ->
    ok = add_code_paths(Root),
    Samples25 = samples(25000, 3, []),
    Samples50 = samples(50000, 3, []),
    Median25 = median(Samples25),
    Median50 = median(Samples50),
    ensure(
        Median50 =< Median25 * 3,
        {growth_limit_exceeded, Median25, Median50}
    ),
    {Elapsed100, Peak100} = measure(100000),
    ensure(Elapsed100 =< ?MAX_100K_MS, {time_limit_exceeded, Elapsed100}),
    ensure(Peak100 < ?MAX_MEMORY_BYTES, {memory_limit_exceeded, Peak100}),
    io:format(
        "Performance gate passed: 25k median=~Bms 50k median=~Bms "
        "100k=~Bms peak=~BMiB.~n",
        [Median25, Median50, Elapsed100, Peak100 div 1048576]
    ),
    ok;
main(_) ->
    io:format(standard_error, "usage: performance-gate.escript REPOSITORY_ROOT~n", []),
    halt(2).

add_code_paths(Root) ->
    code:add_pathsa(filelib:wildcard(filename:join([
        Root, "packages", "beamtrace_core", "build", "dev", "erlang", "*", "ebin"
    ]))).

samples(_Count, 0, Accumulator) -> lists:reverse(Accumulator);
samples(Count, Remaining, Accumulator) ->
    {Elapsed, Peak} = measure(Count),
    ensure(Peak < ?MAX_MEMORY_BYTES, {memory_limit_exceeded, Count, Peak}),
    samples(Count, Remaining - 1, [Elapsed | Accumulator]).

measure(Count) ->
    erlang:garbage_collect(),
    Parent = self(),
    Reference = make_ref(),
    Monitor = spawn(fun() -> memory_monitor(Parent, Reference, erlang:memory(total)) end),
    Started = erlang:monotonic_time(millisecond),
    Events = events(1, Count, []),
    Generated = erlang:monotonic_time(millisecond),
    ok = run_dag(Events),
    DagDone = erlang:monotonic_time(millisecond),
    ok = run_diff(Events),
    DiffDone = erlang:monotonic_time(millisecond),
    ok = run_diagnostics(Events),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    Monitor ! {stop, Reference},
    Peak = receive
        {memory_peak, Reference, Value} -> Value
    after 5000 ->
        erlang:error(memory_monitor_timeout)
    end,
    io:format("sample ~B: generate=~Bms dag=~Bms diff=~Bms diagnostics=~Bms~n", [
        Count,
        Generated - Started,
        DagDone - Generated,
        DiffDone - DagDone,
        Elapsed - (DiffDone - Started)
    ]),
    {Elapsed, Peak}.

events(Current, Limit, Accumulator) when Current > Limit ->
    lists:reverse(Accumulator);
events(Current, Limit, Accumulator) ->
    Number = integer_to_binary(Current),
    Id = <<"event-", Number/binary>>,
    Process = {process_identity,
        {process_ref, <<"benchmark@local">>, <<"<0.1.0>">>},
        none,
        []},
    Event = {trace_event,
        Id,
        <<"root-benchmark">>,
        <<"benchmark@local">>,
        Process,
        {local_instant, Current, Current},
        {stop, Id},
        exact},
    events(Current + 1, Limit, [Event | Accumulator]).

run_dag(Events) ->
    case 'beamtrace@dag':build(Events) of
        {ok, _Graph} -> ok;
        Error -> erlang:error({dag_failed, Error})
    end.

run_diff(Events) ->
    case 'beamtrace@diff':compare(Events, Events) of
        {diff_report, _Items, 0, 0, 0, 0, none} -> ok;
        Report -> erlang:error({diff_failed, Report})
    end.

run_diagnostics(Events) ->
    [] = 'beamtrace@diagnostics':hot_senders(Events, 10),
    [] = 'beamtrace@diagnostics':fan_in(Events, 10),
    [] = 'beamtrace@diagnostics':queue_waits(Events, 1000),
    Outcome = {capture_outcome,
        {quiet_period, 250},
        [],
        [{node_receipt, <<"benchmark@local">>, 1, length(Events), 1}]},
    [] = 'beamtrace@diagnostics':dangling_calls(Events, Outcome, 1000000, 1000),
    [] = 'beamtrace@diagnostics':restart_chains(Events, 1000),
    ok.

memory_monitor(Parent, Reference, Peak) ->
    receive
        {stop, Reference} -> Parent ! {memory_peak, Reference, Peak}
    after 25 ->
        memory_monitor(Parent, Reference, erlang:max(Peak, erlang:memory(total)))
    end.

median(Values) ->
    Sorted = lists:sort(Values),
    lists:nth((length(Sorted) div 2) + 1, Sorted).

ensure(true, _Reason) -> ok;
ensure(false, Reason) ->
    io:format(standard_error, "performance gate failed: ~p~n", [Reason]),
    halt(1).
