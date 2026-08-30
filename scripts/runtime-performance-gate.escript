#!/usr/bin/env escript
%%! +S 4:4 -noshell
%% SPDX-License-Identifier: Apache-2.0 OR MIT

-define(MAX_CAPTURE_100K_MS, 10000).
-define(MAX_SAVE_50K_MS, 30000).
-define(MAX_LOAD_50K_MS, 15000).
-define(MAX_WINDOW_50K_MS, 3000).
-define(MAX_SEARCH_50K_MS, 15000).
-define(MAX_RELAY_DECODE_US, 20000).
-define(MAX_RELAY_INGEST_US, 100000).

main([Root]) ->
    ok = add_code_paths(Root),
    warm_up(),
    {RepeatedCompare, PreparedCompare} = prepared_compare_gate(),
    Capture = capture_gate(),
    {Save, Load, Window, Search} = archive_gate(),
    {Decode, Ingest} = relay_gate(),
    io:format(
        "Runtime performance gate passed: compare repeated=~Bus prepared=~Bus "
        "capture100k=~Bms save50k=~Bms load50k=~Bms window=~Bus "
        "search=~Bms relay_decode=~Bus relay_ingest=~Bus.~n",
        [
            RepeatedCompare,
            PreparedCompare,
            Capture,
            Save,
            Load,
            Window,
            Search,
            Decode,
            Ingest
        ]
    ),
    ok;
main(_) ->
    io:format(
        standard_error,
        "usage: runtime-performance-gate.escript REPOSITORY_ROOT~n",
        []
    ),
    halt(2).

add_code_paths(Root) ->
    Patterns = [
        filename:join([
            Root,
            "packages",
            "beamtrace_core",
            "build",
            "dev",
            "erlang",
            "*",
            "ebin"
        ]),
        filename:join([
            Root,
            "packages",
            "beamtrace_runtime",
            "build",
            "dev",
            "erlang",
            "*",
            "ebin"
        ])
    ],
    code:add_pathsa(lists:append([filelib:wildcard(Pattern) || Pattern <- Patterns])).

warm_up() ->
    CoreEvents = events(1, 500, []),
    _ = 'beamtrace@diff':compare(CoreEvents, CoreEvents),
    _ = 'beamtrace@diff':compare_prepared(
        prepare_checked(CoreEvents),
        prepare_checked(CoreEvents)
    ),
    RawEvents = raw_events(1, 500, []),
    {capture_result, Warmed, _, _} = normalize(RawEvents),
    500 = length(Warmed),
    ok.

prepared_compare_gate() ->
    Events = events(1, 5000, []),
    Repeated = median(samples(fun() -> repeated_compare(Events, 5) end, 3, [])),
    Prepared = median(samples(fun() -> prepared_compare(Events, 5) end, 3, [])),
    ensure(
        Prepared =< Repeated,
        {prepared_compare_regressed, Repeated, Prepared}
    ),
    {Repeated, Prepared}.

repeated_compare(_Events, 0) -> ok;
repeated_compare(Events, Remaining) ->
    {diff_report, _Items, 0, 0, 0, 0, none} =
        'beamtrace@diff':compare(Events, Events),
    repeated_compare(Events, Remaining - 1).

prepared_compare(Events, Count) ->
    Baseline = prepare_checked(Events),
    prepared_compare_candidates(Events, Baseline, Count).

prepared_compare_candidates(_Events, _Baseline, 0) -> ok;
prepared_compare_candidates(Events, Baseline, Remaining) ->
    Candidate = prepare_checked(Events),
    {diff_report, _Items, 0, 0, 0, 0, none} =
        'beamtrace@diff':compare_prepared(Baseline, Candidate),
    prepared_compare_candidates(Events, Baseline, Remaining - 1).

prepare_checked(Events) ->
    case 'beamtrace@diff':prepare(Events) of
        {ok, Prepared} -> Prepared;
        {error, Reason} -> erlang:error({prepare_failed, Reason})
    end.

capture_gate() ->
    Events = raw_events(1, 100000, []),
    {ElapsedUs, {capture_result, Normalized, _, _}} = timed(fun() ->
        normalize(Events)
    end),
    100000 = length(Normalized),
    ElapsedMs = ElapsedUs div 1000,
    ensure(
        ElapsedMs =< ?MAX_CAPTURE_100K_MS,
        {capture_time_limit_exceeded, ElapsedMs}
    ),
    ElapsedMs.

normalize(Events) ->
    Outcome = {raw_outcome,
        <<"quiet_period">>,
        <<"250">>,
        [],
        [{raw_node_receipt, <<"benchmark@local">>, 1, length(Events), 1}]},
    'beamtrace_runtime@capture':normalize_v2(
        Events,
        Outcome,
        {clock_calibration, 0, []},
        {mfa, <<"benchmark">>, <<"run">>, 0}
    ).

raw_events(Current, Limit, Accumulator) when Current > Limit ->
    lists:reverse(Accumulator);
raw_events(Current, Limit, Accumulator) ->
    Number = integer_to_binary(Current),
    Id = <<"capture-event-", Number/binary>>,
    Kind = case Current of
        1 -> <<"root">>;
        _ -> <<"gap">>
    end,
    Metadata = {raw_process_metadata,
        <<"benchmark-worker">>,
        <<>>,
        <<>>,
        <<>>,
        0,
        [],
        <<>>},
    Event = {raw_event_v2,
        Id,
        <<"capture-root">>,
        <<"benchmark@local">>,
        <<"<0.1.0>">>,
        Current,
        Current,
        Kind,
        <<"benchmark@local">>,
        <<"<0.2.0>">>,
        Current - 1,
        Current,
        <<"benchmark:run/0">>,
        Metadata,
        raw_hidden},
    raw_events(Current + 1, Limit, [Event | Accumulator]).

archive_gate() ->
    Events = events(1, 50000, []),
    Manifest = manifest(length(Events)),
    Path = temporary_path("archive"),
    WarmPath = temporary_path("archive-warm"),
    try
        {ok, nil} = 'beamtrace_runtime@storage':save(
            WarmPath,
            manifest(100),
            lists:sublist(Events, 100)
        ),
        {ok, _} = 'beamtrace_runtime@storage':load(WarmPath),
        ok = file:delete(binary_to_list(WarmPath)),
        {SaveUs, {ok, nil}} = timed(fun() ->
            'beamtrace_runtime@storage':save(Path, Manifest, Events)
        end),
        %% Measure full loading as its own warmed workload rather than charging
        %% it for transient allocations left by the preceding save sample.
        erlang:garbage_collect(),
        {LoadUs, {ok, 50000}} = timed(fun() -> isolated_load_count(Path) end),
        WindowUs = median(samples(fun() ->
            {ok, {event_window, WindowEvents, 50000, 24999, 10, _}} =
                'beamtrace_runtime@storage':window(Path, 24999, 10),
            10 = length(WindowEvents),
            ok
        end, 3, [])),
        {SearchUs, {ok, {event_window, Matches, 1, 0, 10, _}}} = timed(fun() ->
            'beamtrace_runtime@storage':search(Path, <<"event-50000">>, 0, 10)
        end),
        1 = length(Matches),
        SaveMs = SaveUs div 1000,
        LoadMs = LoadUs div 1000,
        SearchMs = SearchUs div 1000,
        ensure(SaveMs =< ?MAX_SAVE_50K_MS, {save_time_limit_exceeded, SaveMs}),
        ensure(LoadMs =< ?MAX_LOAD_50K_MS, {load_time_limit_exceeded, LoadMs}),
        ensure(
            WindowUs div 1000 =< ?MAX_WINDOW_50K_MS,
            {window_time_limit_exceeded, WindowUs}
        ),
        ensure(
            SearchMs =< ?MAX_SEARCH_50K_MS,
            {search_time_limit_exceeded, SearchMs}
        ),
        ensure(WindowUs < LoadUs, {selective_window_regressed, LoadUs, WindowUs}),
        ensure(SearchUs < LoadUs, {selective_search_regressed, LoadUs, SearchUs}),
        {SaveMs, LoadMs, WindowUs, SearchMs}
    after
        _ = file:delete(binary_to_list(Path)),
        _ = file:delete(binary_to_list(WarmPath))
    end.

%% A real caller can release a loaded archive with its request process. Run the
%% full-load sample in such a process so earlier save/compare heap growth does
%% not become part of the archive decoder measurement.
isolated_load_count(Path) ->
    Parent = self(),
    Reference = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Result = case 'beamtrace_runtime@storage':load(Path) of
            {ok, {archive, _Manifest, Events, _Graph, _Clocks}} ->
                {ok, length(Events)};
            Error -> Error
        end,
        Parent ! {Reference, Result}
    end),
    receive
        {Reference, Result} ->
            receive
                {'DOWN', Monitor, process, Pid, normal} -> Result;
                {'DOWN', Monitor, process, Pid, Reason} ->
                    erlang:error({load_worker_failed, Reason})
            end;
        {'DOWN', Monitor, process, Pid, Reason} ->
            erlang:error({load_worker_failed, Reason})
    after 60000 ->
        erlang:error(load_worker_timeout)
    end.

manifest(EventCount) ->
    {manifest,
        2,
        <<"0.3.0">>,
        <<"performance-capture">>,
        [<<"benchmark@local">>],
        {capture_outcome,
            {quiet_period, 250},
            [],
            [{node_receipt, <<"benchmark@local">>, 1, EventCount, 1}]},
        metadata}.

relay_gate() ->
    Events = lists:sublist(events(1, 128, []), 128),
    {ok, Payload} = 'beamtrace_runtime@relay_payload':encode(
        <<"exact">>, Events
    ),
    {ok, _} = 'beamtrace_runtime@relay_payload':decode_for_ingest(Payload),
    DecodeTotal = median(samples(fun() -> decode_many(Payload, 100) end, 3, [])),
    Decode = DecodeTotal div 100,
    Ingest = median(value_samples(fun() -> ingest_once(Payload) end, 3, [])),
    ensure(
        Decode =< ?MAX_RELAY_DECODE_US,
        {relay_decode_time_limit_exceeded, Decode}
    ),
    ensure(
        Ingest =< ?MAX_RELAY_INGEST_US,
        {relay_ingest_time_limit_exceeded, Ingest}
    ),
    {Decode, Ingest}.

decode_many(_Payload, 0) -> ok;
decode_many(Payload, Remaining) ->
    {ok, {batch, <<"exact">>, 128, _Canonical, metadata_batch, _Events}} =
        'beamtrace_runtime@relay_payload':decode_for_ingest(Payload),
    decode_many(Payload, Remaining - 1).

ingest_once(Payload) ->
    {ok, Metadata} = 'beamtrace_runtime@team_store':open(<<":memory:">>),
    Inbox = 'beamtrace_runtime@relay_inbox':new(4, 10000000),
    Root = temporary_path("ingest"),
    try
        {Elapsed, {ok, accepted}} = timed(fun() ->
            'beamtrace_runtime@relay_ingest':accept(
                Metadata,
                Root,
                Inbox,
                <<"relay-1234567890abcdef12345678">>,
                1,
                exact,
                Payload,
                1000
            )
        end),
        Elapsed
    after
        _ = 'beamtrace_runtime@relay_inbox':close(Inbox),
        _ = 'beamtrace_runtime@team_store':close(Metadata),
        _ = file:del_dir_r(binary_to_list(Root))
    end.

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

samples(_Run, 0, Accumulator) -> lists:reverse(Accumulator);
samples(Run, Remaining, Accumulator) ->
    erlang:garbage_collect(),
    {Elapsed, ok} = timed(Run),
    samples(Run, Remaining - 1, [Elapsed | Accumulator]).

value_samples(_Run, 0, Accumulator) -> lists:reverse(Accumulator);
value_samples(Run, Remaining, Accumulator) ->
    erlang:garbage_collect(),
    value_samples(Run, Remaining - 1, [Run() | Accumulator]).

timed(Run) ->
    Started = erlang:monotonic_time(microsecond),
    Result = Run(),
    {erlang:monotonic_time(microsecond) - Started, Result}.

median(Values) ->
    Sorted = lists:sort(Values),
    lists:nth((length(Sorted) div 2) + 1, Sorted).

temporary_path(Label) ->
    Unique = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    iolist_to_binary([<<"/tmp/beamtrace-performance-">>, Label, <<"-">>, Unique]).

ensure(true, _Reason) -> ok;
ensure(false, Reason) ->
    io:format(standard_error, "runtime performance gate failed: ~p~n", [Reason]),
    halt(1).
