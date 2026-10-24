#!/usr/bin/env escript
%%! +S 4:4 -noshell
%% SPDX-License-Identifier: Apache-2.0 OR MIT

-define(MAX_100K_MS, 60000).
-define(MAX_MEMORY_BYTES, 1073741824).

-record(sample, {
    elapsed :: non_neg_integer(),
    peak :: non_neg_integer(),
    reductions :: non_neg_integer()
}).

main(["--self-test"]) ->
    self_test();
main([Root, "--one", CountSource]) ->
    ok = add_code_paths(Root),
    #sample{elapsed = Elapsed, peak = Peak} = measure(list_to_integer(CountSource)),
    io:format("elapsed=~Bms peak=~BMiB~n", [Elapsed, Peak div 1048576]),
    ok;
main([Root]) ->
    ok = add_code_paths(Root),
    Samples25 = samples(25000, 3, []),
    Samples50 = samples(50000, 3, []),
    {Allowed, Median25, Median50} = growth(Samples25, Samples50),
    ensure(
        Allowed,
        {growth_limit_exceeded, Median25, Median50}
    ),
    #sample{elapsed = Elapsed100, peak = Peak100} = measure(100000),
    ensure(Elapsed100 =< ?MAX_100K_MS, {time_limit_exceeded, Elapsed100}),
    ensure(Peak100 < ?MAX_MEMORY_BYTES, {memory_limit_exceeded, Peak100}),
    io:format(
        "Performance gate passed: 25k work=~B 50k work=~B "
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
    Sample = #sample{peak = Peak} = measure(Count),
    ensure(Peak < ?MAX_MEMORY_BYTES, {memory_limit_exceeded, Count, Peak}),
    samples(Count, Remaining - 1, [Sample | Accumulator]).

-spec measure(pos_integer()) -> #sample{}.
measure(Count) ->
    isolated(fun() -> measure_in_process(Count) end).

-spec measure_in_process(pos_integer()) -> #sample{}.
measure_in_process(Count) ->
    erlang:garbage_collect(),
    Parent = self(),
    Reference = make_ref(),
    Monitor = spawn_link(fun() -> memory_monitor(Parent, Reference, erlang:memory(total)) end),
    BeforeWork = reductions(),
    Started = erlang:monotonic_time(millisecond),
    Events = events(1, Count, []),
    Generated = erlang:monotonic_time(millisecond),
    ok = run_dag(Events),
    DagDone = erlang:monotonic_time(millisecond),
    ok = run_diff(Events),
    DiffDone = erlang:monotonic_time(millisecond),
    ok = run_diagnostics(Events),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    Work = reductions() - BeforeWork,
    Monitor ! {stop, Reference},
    Peak = receive
        {memory_peak, Reference, Value} -> Value
    after 5000 ->
        erlang:error(memory_monitor_timeout)
    end,
    io:format("sample ~B: generate=~Bms dag=~Bms diff=~Bms diagnostics=~Bms reductions=~B~n", [
        Count,
        Generated - Started,
        DagDone - Generated,
        DiffDone - DagDone,
        Elapsed - (DiffDone - Started),
        Work
    ]),
    #sample{elapsed = Elapsed, peak = Peak, reductions = Work}.

-spec isolated(fun(() -> Result)) -> Result.
isolated(Work) ->
    Parent = self(),
    Reference = make_ref(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        Parent ! {Reference, Work()}
    end),
    receive
        {Reference, Result} ->
            receive
                {'DOWN', Monitor, process, Worker, normal} -> Result;
                {'DOWN', Monitor, process, Worker, Reason} ->
                    error({sample_failed, Reason})
            end;
        {'DOWN', Monitor, process, Worker, Reason} -> error({sample_failed, Reason})
    end.

-spec reductions() -> non_neg_integer().
reductions() ->
    {reductions, Count} = process_info(self(), reductions),
    Count.

-spec growth([#sample{}], [#sample{}]) -> {boolean(), non_neg_integer(), non_neg_integer()}.
growth(Small, Large) ->
    Median25 = median([Work || #sample{reductions = Work} <- Small]),
    Median50 = median([Work || #sample{reductions = Work} <- Large]),
    {Median25 > 0 andalso Median50 > 0 andalso Median50 =< Median25 * 3,
        Median25, Median50}.

-spec self_test() -> ok.
self_test() ->
    Caller = self(),
    put(performance_probe, caller),
    {First, undefined} = isolated(fun() -> {self(), get(performance_probe)} end),
    Second = isolated(fun() -> self() end),
    ensure(First /= Caller andalso First /= Second, inherited_worker_state),
    Small = #sample{elapsed = 1, peak = 0, reductions = 100},
    Slow = #sample{elapsed = 10000, peak = 0, reductions = 200},
    {true, 100, 200} = growth([Small], [Slow]),
    Quadratic = #sample{elapsed = 1, peak = 0, reductions = 400},
    {false, 100, 400} = growth([Small], [Quadratic]),
    {true, 100, 300} = growth([Small], [Quadratic#sample{reductions = 300}]),
    {false, 100, 301} = growth([Small], [Quadratic#sample{reductions = 301}]),
    {false, 0, 0} = growth([Small#sample{reductions = 0}], [Slow#sample{reductions = 0}]),
    {true, 100, 200} = growth([Small, Slow, Small], [Slow, Quadratic, Slow]),
    try isolated(fun() -> error(planted_worker_failure) end) of
        _ -> error(worker_failure_accepted)
    catch
        error:{sample_failed, {planted_worker_failure, _}} -> ok
    end,
    erase(performance_probe),
    io:format("Performance measurement contracts passed.~n"),
    ok.

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
        {ok, {diff_report, _Items, 0, 0, 0, 0, none}} -> ok;
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
