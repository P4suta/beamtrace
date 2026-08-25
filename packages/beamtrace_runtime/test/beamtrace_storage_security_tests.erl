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
