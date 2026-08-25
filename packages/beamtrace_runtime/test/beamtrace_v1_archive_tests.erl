%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_v1_archive_tests).

-include_lib("eunit/include/eunit.hrl").

v1_golden_is_read_and_migrated_without_mutating_source_test() ->
    Source = temporary_path("v1-source"),
    Output = temporary_path("v2-output"),
    try
        ok = create_v1_golden(Source),
        {ok, Before} = file:read_file(Source),
        {ok, {Manifest, Events, [], <<>>}} = beamtrace_storage_ffi:read_container(
            unicode:characters_to_binary(Source)
        ),
        ?assertMatch(<<"{\"schema_version\":1,", _/binary>>, Manifest),
        ?assertEqual(1, length(Events)),
        ?assertEqual(
            {ok, nil},
            'beamtrace_runtime@storage':migrate(
                unicode:characters_to_binary(Source),
                unicode:characters_to_binary(Output),
                <<"0.3.0">>
            )
        ),
        {ok, After} = file:read_file(Source),
        ?assertEqual(Before, After),
        {ok, {V2Manifest, _V2Events, [_], V2Clocks}} =
            beamtrace_storage_ffi:read_container(
                unicode:characters_to_binary(Output)
            ),
        ?assertMatch(<<"{\"schema_version\":2,", _/binary>>, V2Manifest),
        ?assertMatch(<<"{\"schema_version\":2,", _/binary>>, V2Clocks)
    after
        _ = file:delete(Source),
        _ = file:delete(Output)
    end.

migration_refuses_to_overwrite_its_source_test() ->
    Path = temporary_path("v1-same-path"),
    try
        ok = create_v1_golden(Path),
        ?assertEqual(
            {error, migration_requires_distinct_output},
            'beamtrace_runtime@storage':migrate(
                unicode:characters_to_binary(Path),
                unicode:characters_to_binary(Path),
                <<"0.3.0">>
            )
        )
    after
        _ = file:delete(Path)
    end.

create_v1_golden(Path) ->
    {ok, Manifest0} = file:read_file(fixture("manifest.json")),
    {ok, Event0} = file:read_file(fixture("event.json")),
    Manifest = trim_newline(Manifest0),
    Event = trim_newline(Event0),
    EventData = <<Event/binary, "\n">>,
    Index = <<"{\"schema_version\":1,\"segments\":[{\"path\":\"events/000001.ndjson\",\"first\":0,\"count\":1}]}">>,
    DataEntries = [
        {"manifest.json", Manifest},
        {"events/000001.ndjson", EventData},
        {"processes.ndjson", <<>>},
        {"annotations.json", <<"[]">>},
        {"indexes/events.idx", Index}
    ],
    Checksums = checksum_inventory(DataEntries),
    {ok, _} = zip:create(Path, DataEntries ++ [{"checksums.json", Checksums}], []),
    ok.

fixture(Name) ->
    filename:join(["..", "..", "fixtures", "format-v1", Name]).

temporary_path(Label) ->
    ok = filelib:ensure_dir(filename:join("build", "v1-golden-placeholder")),
    filename:join(
        "build",
        Label ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))
            ++ ".beamtrace"
    ).

checksum_inventory(Entries) ->
    Items = [
        iolist_to_binary([
            <<"{\"path\":\"">>, unicode:characters_to_binary(Name),
            <<"\",\"sha256\":\"">>, sha256_hex(Data), <<"\"}">>
        ])
        || {Name, Data} <- Entries
    ],
    iolist_to_binary([
        <<"{\"algorithm\":\"sha256\",\"files\":[">>,
        lists:join(<<",">>, Items),
        <<"]}">>
    ]).

sha256_hex(Data) ->
    Digest = crypto:hash(sha256, Data),
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>>
       || <<Byte>> <= Digest >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.

trim_newline(Binary) ->
    string:trim(Binary, trailing, "\r\n").
