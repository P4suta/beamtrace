%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_storage_security_tests).

-include_lib("eunit/include/eunit.hrl").

unsafe_entry_is_rejected_before_extraction_test() ->
    with_zip([{"../escape", <<"sentinel">>}], fun(Path) ->
        ?assertEqual(
            {error, <<"unsafe_entry:../escape">>},
            beamtrace_storage_ffi:list_entries(unicode:characters_to_binary(Path))
        )
    end).

duplicate_entry_names_are_rejected_test() ->
    with_zip([
        {"manifest.json", <<"first">>},
        {"manifest.json", <<"second">>}
    ], fun(Path) ->
        ?assertEqual(
            {error, <<"duplicate_entry:manifest.json">>},
            beamtrace_storage_ffi:list_entries(unicode:characters_to_binary(Path))
        )
    end).

high_compression_ratio_is_rejected_as_zip_bomb_test() ->
    Payload = binary:copy(<<0>>, 2 * 1024 * 1024),
    with_zip([{"events/000001.ndjson", Payload}], fun(Path) ->
        ?assertEqual(
            {error, <<"zip_bomb">>},
            beamtrace_storage_ffi:list_entries(unicode:characters_to_binary(Path))
        )
    end).

checksum_tampering_is_rejected_test() ->
    Path = temporary_path(),
    PathBinary = unicode:characters_to_binary(Path),
    try
        ?assertEqual(
            {ok, nil},
            beamtrace_storage_ffi:write_container(
                PathBinary,
                <<"{\"schema_version\":2}">>,
                [<<"{\"schema_version\":2,\"id\":\"one\"}">>],
                [<<"{\"schema_version\":2,\"event_ids\":[\"one\"],\"edges\":[],\"boundaries\":[]}">>],
                <<"{\"schema_version\":2,\"capture_anchor_unix_ns\":\"0\",\"nodes\":[]}">>
            )
        ),
        {ok, Extracted} = zip:extract(Path, [memory]),
        Tampered = lists:keyreplace(
            "events/000001.ndjson",
            1,
            Extracted,
            {"events/000001.ndjson", <<"{\"id\":\"sentinel\"}\n">>}
        ),
        ok = file:delete(Path),
        {ok, _} = zip:create(Path, Tampered, []),
        ?assertEqual(
            {error, <<"checksum_mismatch">>},
            beamtrace_storage_ffi:read_container(PathBinary)
        )
    after
        _ = file:delete(Path)
    end.

selective_window_verifies_selected_segments_and_full_validation_checks_all_test() ->
    Path = temporary_path(),
    PathBinary = unicode:characters_to_binary(Path),
    Event = <<"{\"schema_version\":2,\"id\":\"one\"}">>,
    Graph = <<"{\"schema_version\":2,\"event_ids\":[],\"edges\":[],\"boundaries\":[]}">>,
    try
        ?assertEqual(
            {ok, nil},
            beamtrace_storage_ffi:write_container(
                PathBinary,
                <<"{\"schema_version\":2}">>,
                lists:duplicate(1001, Event),
                [Graph, Graph],
                <<"{\"schema_version\":2,\"capture_anchor_unix_ns\":\"0\",\"nodes\":[]}">>
            )
        ),
        ok = tamper_entry(Path, "events/000002.ndjson", <<"{\"tampered\":true}\n">>),
        ?assertMatch(
            {ok, {_, [_], _, 1001}},
            beamtrace_storage_ffi:read_window(PathBinary, 0, 1)
        ),
        ?assertEqual(
            {error, <<"checksum_mismatch">>},
            beamtrace_storage_ffi:search_container(
                PathBinary, <<"not-present">>, 0, 1
            )
        ),
        ?assertEqual(
            {error, <<"checksum_mismatch">>},
            beamtrace_storage_ffi:read_container(PathBinary)
        )
    after
        _ = file:delete(Path)
    end.

selective_window_rejects_a_tampered_selected_segment_test() ->
    Path = temporary_path(),
    PathBinary = unicode:characters_to_binary(Path),
    Graph = <<"{\"schema_version\":2,\"event_ids\":[],\"edges\":[],\"boundaries\":[]}">>,
    try
        ?assertEqual(
            {ok, nil},
            beamtrace_storage_ffi:write_container(
                PathBinary,
                <<"{\"schema_version\":2}">>,
                [<<"{\"schema_version\":2,\"id\":\"one\"}">>],
                [Graph],
                <<"{\"schema_version\":2,\"capture_anchor_unix_ns\":\"0\",\"nodes\":[]}">>
            )
        ),
        ok = tamper_entry(Path, "events/000001.ndjson", <<"{\"tampered\":true}\n">>),
        ?assertEqual(
            {error, <<"checksum_mismatch">>},
            beamtrace_storage_ffi:read_window(PathBinary, 0, 1)
        )
    after
        _ = file:delete(Path)
    end.

parallel_event_decode_preserves_order_and_the_first_error_test() ->
    First = parallel_event(<<"first">>),
    Last = parallel_event(<<"last">>),
    FirstLine = 'beamtrace@codec':encode_event(First),
    LastLine = 'beamtrace@codec':encode_event(Last),
    Lines = lists:duplicate(1000, FirstLine) ++ [LastLine],
    {ok, Events} = beamtrace_storage_ffi:decode_events_parallel(Lines),
    ?assertEqual(1001, length(Events)),
    ?assertEqual(First, hd(Events)),
    ?assertEqual(Last, lists:last(Events)),

    %% The second worker fails immediately, while the first decodes 500 valid
    %% events before failing. The public result must still follow input order.
    Invalid = lists:duplicate(500, FirstLine)
        ++ [<<"not-json">>, <<"{\"schema_version\":99}">>]
        ++ lists:duplicate(499, FirstLine),
    ?assertMatch(
        {error, {invalid_json, _}},
        beamtrace_storage_ffi:decode_events_parallel(Invalid)
    ).

parallel_event(Id) ->
    {trace_event,
        Id,
        <<"root-parallel">>,
        <<"parallel@local">>,
        {process_identity,
            {process_ref, <<"parallel@local">>, <<"<0.1.0>">>},
            none,
            []},
        {local_instant, 1, 1},
        {stop, <<"complete">>},
        exact}.

tamper_entry(Path, Name, Replacement) ->
    {ok, Extracted} = zip:extract(Path, [memory]),
    Tampered = lists:keyreplace(Name, 1, Extracted, {Name, Replacement}),
    ok = file:delete(Path),
    {ok, _} = zip:create(Path, Tampered, []),
    ok.

with_zip(Entries, Assertion) ->
    Path = temporary_path(),
    try
        {ok, _} = zip:create(Path, Entries, []),
        Assertion(Path)
    after
        _ = file:delete(Path)
    end.

temporary_path() ->
    ok = filelib:ensure_dir(filename:join("build", "storage-security-placeholder")),
    filename:join(
        "build",
        "storage-security-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".zip"
    ).
