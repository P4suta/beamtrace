%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_storage_ffi).

-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/zip.hrl").

-export([write_container/5, read_container/1, list_entries/1]).

-define(MAX_ENTRIES, 10000).
-define(MAX_UNCOMPRESSED_BYTES, 1073741824).
-define(MAX_COMPRESSION_RATIO, 200).
-define(MAX_ENTRY_BYTES, 67108864).
-define(SEGMENT_EVENTS, 1000).

write_container(PathBinary, Manifest, EventLines, GraphSegments, Clocks)
        when is_binary(PathBinary), is_binary(Manifest), is_list(EventLines),
             is_list(GraphSegments), is_binary(Clocks) ->
    Path = unicode:characters_to_list(PathBinary),
    case filelib:ensure_dir(Path) of
        ok -> write_container_file(Path, Manifest, EventLines, GraphSegments, Clocks);
        {error, Reason} -> {error, error_binary({ensure_directory, Reason})}
    end;
write_container(_Path, _Manifest, _Events, _Graphs, _Clocks) ->
    {error, <<"invalid_container">>}.

write_container_file(Path, Manifest, EventLines, GraphSegments, Clocks) ->
    EventEntries = event_entries(EventLines),
    case graph_entries(GraphSegments, length(EventEntries)) of
        {error, Reason} -> {error, Reason};
        {ok, GraphEntries} ->
            Index = index_json(2, EventEntries),
            Annotations = <<"{\"schema_version\":2,\"annotations\":[]}">>,
            DataEntries =
                [{"manifest.json", Manifest}]
                ++ EventEntries
                ++ GraphEntries
                ++ [
                    {"clocks.json", Clocks},
                    {"indexes/events.idx", Index},
                    {"annotations.json", Annotations}
                ],
            Checksums = checksums_json(DataEntries),
            Entries = DataEntries ++ [{"checksums.json", Checksums}],
            Temporary = Path ++ ".tmp." ++ integer_to_list(
                erlang:unique_integer([positive, monotonic])
            ),
            case zip:create(Temporary, Entries, []) of
                {ok, _} -> atomic_replace(Temporary, Path);
                {error, ZipReason} ->
                    _ = file:delete(Temporary),
                    {error, error_binary({zip_create, ZipReason})}
            end
    end.

%% `file:rename/2` is an atomic replacement on the supported Unix targets. We
%% deliberately do not unlink the destination first: any failure leaves the
%% previous archive intact.
atomic_replace(Temporary, Path) ->
    _ = sync_file(Temporary),
    case file:rename(Temporary, Path) of
        ok -> {ok, nil};
        {error, Reason} ->
            _ = file:delete(Temporary),
            {error, error_binary({atomic_replace, Reason})}
    end.

sync_file(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Device} ->
            Result = file:sync(Device),
            _ = file:close(Device),
            Result;
        Error -> Error
    end.

event_entries([]) -> [{"events/000001.ndjson", <<>>}];
event_entries(EventLines) -> event_entries(EventLines, 1, []).

event_entries([], _Sequence, Accumulator) -> lists:reverse(Accumulator);
event_entries(EventLines, Sequence, Accumulator) ->
    {Chunk, Rest} = take_lines(EventLines, ?SEGMENT_EVENTS, []),
    Name = lists:flatten(io_lib:format("events/~6..0B.ndjson", [Sequence])),
    event_entries(Rest, Sequence + 1, [{Name, ndjson(Chunk)} | Accumulator]).

graph_entries(GraphSegments, ExpectedCount)
        when length(GraphSegments) =:= ExpectedCount ->
    case lists:all(fun is_binary/1, GraphSegments) of
        true ->
            {ok, lists:zipwith(fun(Sequence, Data) ->
                Name = lists:flatten(io_lib:format("graph/~6..0B.json", [Sequence])),
                {Name, Data}
            end, lists:seq(1, ExpectedCount), GraphSegments)};
        false -> {error, <<"invalid_container">>}
    end;
graph_entries(_GraphSegments, _ExpectedCount) ->
    {error, <<"graph_segment_count_mismatch">>}.

take_lines(Rest, 0, Accumulator) -> {lists:reverse(Accumulator), Rest};
take_lines([], _Remaining, Accumulator) -> {lists:reverse(Accumulator), []};
take_lines([Line | Rest], Remaining, Accumulator) when is_binary(Line) ->
    take_lines(Rest, Remaining - 1, [Line | Accumulator]);
take_lines([_Invalid | _Rest], _Remaining, _Accumulator) ->
    erlang:error(invalid_event_line).

index_json(Version, EventEntries) ->
    {Items, _NextFirst} = lists:mapfoldl(fun({Name, Data}, First) ->
        Count = length(split_ndjson(Data)),
        Item = [
            <<"{\"path\":\"">>,
            unicode:characters_to_binary(Name),
            <<"\",\"first\":">>,
            integer_to_binary(First),
            <<",\"count\":">>,
            integer_to_binary(Count),
            <<"}">>
        ],
        {Item, First + Count}
    end, 0, EventEntries),
    iolist_to_binary([
        <<"{\"schema_version\":" >>,
        integer_to_binary(Version),
        <<",\"segments\":[">>,
        lists:join(<<",">>, Items),
        <<"]}">>
    ]).

read_container(PathBinary) when is_binary(PathBinary) ->
    Path = unicode:characters_to_list(PathBinary),
    case validated_table(Path) of
        {ok, Files} ->
            case zip:extract(Path, [memory]) of
                {ok, Extracted} -> decode_extracted(Files, Extracted);
                {error, _Reason} -> {error, <<"invalid_container">>}
            end;
        Error -> Error
    end;
read_container(_Path) -> {error, <<"invalid_container">>}.

list_entries(PathBinary) when is_binary(PathBinary) ->
    Path = unicode:characters_to_list(PathBinary),
    case validated_table(Path) of
        {ok, Files} ->
            case zip:extract(Path, [memory]) of
                {ok, Extracted} ->
                    case decode_extracted(Files, Extracted) of
                        {ok, _Payload} ->
                            {ok, [unicode:characters_to_binary(File#zip_file.name)
                                  || File <- Files]};
                        Error -> Error
                    end;
                {error, _Reason} -> {error, <<"invalid_container">>}
            end;
        Error -> Error
    end;
list_entries(_Path) -> {error, <<"invalid_container">>}.

validated_table(Path) ->
    case zip:table(Path) of
        {ok, Entries} ->
            Files = [Entry || Entry <- Entries, is_record(Entry, zip_file)],
            validate_files(Files);
        {error, _Reason} -> {error, <<"invalid_container">>}
    end.

validate_files(Files) when length(Files) > ?MAX_ENTRIES ->
    {error, <<"zip_bomb">>};
validate_files(Files) ->
    case validate_names(Files) of
        ok ->
            case validate_unique_names(Files, #{}) of
                ok -> validate_sizes(Files);
                Error -> Error
            end;
        Error -> Error
    end.

validate_names([]) -> ok;
validate_names([File | Rest]) ->
    Name = File#zip_file.name,
    Info = File#zip_file.info,
    case safe_entry_name(Name) andalso Info#file_info.type =:= regular of
        true -> validate_names(Rest);
        false ->
            {error, <<"unsafe_entry:", (unicode:characters_to_binary(Name))/binary>>}
    end.

validate_unique_names([], _Seen) -> ok;
validate_unique_names([File | Rest], Seen) ->
    Name = File#zip_file.name,
    case maps:is_key(Name, Seen) of
        true ->
            {error, <<"duplicate_entry:", (unicode:characters_to_binary(Name))/binary>>};
        false -> validate_unique_names(Rest, maps:put(Name, true, Seen))
    end.

validate_sizes(Files) ->
    Total = lists:sum([(File#zip_file.info)#file_info.size || File <- Files]),
    OversizedEntry = lists:any(fun(File) ->
        (File#zip_file.info)#file_info.size > ?MAX_ENTRY_BYTES
    end, Files),
    case Total > ?MAX_UNCOMPRESSED_BYTES
         orelse OversizedEntry
         orelse has_suspicious_ratio(Files) of
        true -> {error, <<"zip_bomb">>};
        false -> {ok, Files}
    end.

safe_entry_name(Name) ->
    Segments = string:tokens(Name, "/"),
    filename:pathtype(Name) =:= relative
        andalso not lists:member("..", Segments)
        andalso not lists:member("", Segments)
        andalso not lists:member(0, Name)
        andalso not lists:member($:, Name)
        andalso not lists:member($\\, Name).

has_suspicious_ratio(Files) ->
    lists:any(fun(File) ->
        Size = (File#zip_file.info)#file_info.size,
        Compressed = File#zip_file.comp_size,
        Size > 1048576 andalso (
            Compressed =:= 0
            orelse Size div erlang:max(Compressed, 1) > ?MAX_COMPRESSION_RATIO
        )
    end, Files).

decode_extracted(Files, Extracted) ->
    ByName = maps:from_list([
        {unicode:characters_to_binary(Name), Data}
        || {Name, Data} <- Extracted,
           is_binary(Data)
    ]),
    case map_size(ByName) =:= length(Files) of
        false -> {error, <<"invalid_container">>};
        true ->
            case maps:find(<<"manifest.json">>, ByName) of
                error -> {error, <<"invalid_container">>};
                {ok, Manifest} -> dispatch_schema(Manifest, ByName)
            end
    end.

%% Manifest schema dispatch happens before interpreting any version-specific
%% archive entry.
dispatch_schema(Manifest, ByName) ->
    case manifest_schema(Manifest) of
        {ok, 1} -> decode_v1(Manifest, ByName);
        {ok, 2} -> decode_v2(Manifest, ByName);
        {ok, Version} ->
            {error, <<"unknown_schema_version:", (integer_to_binary(Version))/binary>>};
        error -> {error, <<"invalid_container">>}
    end.

manifest_schema(Manifest) ->
    try json:decode(Manifest) of
        Object when is_map(Object), map_size(Object) > 0 ->
            case maps:get(<<"schema_version">>, Object, undefined) of
                Version when is_integer(Version) -> {ok, Version};
                _ -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end.

decode_v1(Manifest, ByName) ->
    case canonical_segments(ByName, <<"events/">>, <<".ndjson">>) of
        {error, _} = Error -> Error;
        {ok, EventNames} ->
            DataNames = [<<"manifest.json">>]
                ++ EventNames
                ++ [
                    <<"processes.ndjson">>,
                    <<"annotations.json">>,
                    <<"indexes/events.idx">>
                ],
            case exact_entries(ByName, DataNames)
                 andalso canonical_event_segments(ByName, EventNames)
                 andalso maps:get(<<"processes.ndjson">>, ByName, invalid) =:= <<>>
                 andalso maps:get(<<"annotations.json">>, ByName, invalid) =:= <<"[]">>
                 andalso maps:get(<<"indexes/events.idx">>, ByName, invalid)
                     =:= index_json(1, named_data(EventNames, ByName)) of
                false -> {error, <<"invalid_container">>};
                true ->
                    case verify_all_checksums(ByName, DataNames) of
                        ok ->
                            Events = lists:append([
                                split_ndjson(maps:get(Name, ByName))
                                || Name <- EventNames
                            ]),
                            {ok, {Manifest, Events, [], <<>>}};
                        Error -> Error
                    end
            end
    end.

decode_v2(Manifest, ByName) ->
    case {
        canonical_segments(ByName, <<"events/">>, <<".ndjson">>),
        canonical_segments(ByName, <<"graph/">>, <<".json">>)
    } of
        {{ok, EventNames}, {ok, GraphNames}}
                when length(EventNames) =:= length(GraphNames) ->
            DataNames = [<<"manifest.json">>]
                ++ EventNames
                ++ GraphNames
                ++ [
                    <<"clocks.json">>,
                    <<"indexes/events.idx">>,
                    <<"annotations.json">>
                ],
            case exact_entries(ByName, DataNames)
                 andalso canonical_event_segments(ByName, EventNames)
                 andalso maps:get(<<"indexes/events.idx">>, ByName, invalid)
                     =:= index_json(2, named_data(EventNames, ByName))
                 andalso maps:get(<<"annotations.json">>, ByName, invalid)
                     =:= <<"{\"schema_version\":2,\"annotations\":[]}">> of
                false -> {error, <<"invalid_container">>};
                true ->
                    case verify_all_checksums(ByName, DataNames) of
                        ok ->
                            Events = lists:append([
                                split_ndjson(maps:get(Name, ByName))
                                || Name <- EventNames
                            ]),
                            Graphs = [maps:get(Name, ByName) || Name <- GraphNames],
                            Clocks = maps:get(<<"clocks.json">>, ByName),
                            {ok, {Manifest, Events, Graphs, Clocks}};
                        Error -> Error
                    end
            end;
        _ -> {error, <<"invalid_container">>}
    end.

canonical_segments(ByName, Prefix, Suffix) ->
    Names = lists:sort([
        Name || Name <- maps:keys(ByName),
            has_prefix_suffix(Name, Prefix, Suffix)
    ]),
    Expected = segment_names(Prefix, Suffix, length(Names)),
    case Names =/= [] andalso Names =:= Expected of
        true -> {ok, Names};
        false -> {error, <<"invalid_container">>}
    end.

segment_names(Prefix, Suffix, Count) ->
    [
        iolist_to_binary([
            Prefix,
            io_lib:format("~6..0B", [Sequence]),
            Suffix
        ])
        || Sequence <- lists:seq(1, Count)
    ].

has_prefix_suffix(Name, Prefix, Suffix) ->
    PrefixSize = byte_size(Prefix),
    SuffixSize = byte_size(Suffix),
    byte_size(Name) > PrefixSize + SuffixSize
        andalso binary:part(Name, 0, PrefixSize) =:= Prefix
        andalso binary:part(Name, byte_size(Name) - SuffixSize, SuffixSize) =:= Suffix.

canonical_event_segments(ByName, Names) ->
    canonical_event_segments(ByName, Names, length(Names)).

canonical_event_segments(_ByName, [], _Total) -> false;
canonical_event_segments(ByName, Names, Total) ->
    lists:all(fun({Name, Position}) ->
        Data = maps:get(Name, ByName),
        Lines = split_ndjson(Data),
        Count = length(Lines),
        CanonicalCount = case Position < Total of
            true -> Count =:= ?SEGMENT_EVENTS;
            false -> Count >= 0 andalso Count =< ?SEGMENT_EVENTS
        end,
        CanonicalCount andalso Data =:= ndjson(Lines)
    end, lists:zip(Names, lists:seq(1, Total))).

exact_entries(ByName, DataNames) ->
    Actual = lists:sort(maps:keys(ByName)),
    Expected = lists:sort([<<"checksums.json">> | DataNames]),
    Actual =:= Expected.

named_data(Names, ByName) ->
    [{unicode:characters_to_list(Name), maps:get(Name, ByName)} || Name <- Names].

verify_all_checksums(ByName, DataNames) ->
    case maps:find(<<"checksums.json">>, ByName) of
        error -> {error, <<"invalid_checksums">>};
        {ok, Source} ->
            case parse_checksums(Source, DataNames) of
                ok ->
                    Entries = [
                        {unicode:characters_to_list(Name), maps:get(Name, ByName)}
                        || Name <- DataNames
                    ],
                    case Source =:= checksums_json(Entries) of
                        true -> ok;
                        false -> {error, <<"checksum_mismatch">>}
                    end;
                error -> {error, <<"invalid_checksums">>}
            end
    end.

parse_checksums(Source, ExpectedNames) ->
    try json:decode(Source) of
        Object when is_map(Object), map_size(Object) =:= 2 ->
            case {
                maps:get(<<"algorithm">>, Object, undefined),
                maps:get(<<"files">>, Object, undefined)
            } of
                {<<"sha256">>, Files} when is_list(Files) ->
                    case parse_checksum_files(Files, #{}, []) of
                        {ok, Paths} when Paths =:= ExpectedNames -> ok;
                        _ -> error
                    end;
                _ -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end.

parse_checksum_files([], _Seen, Accumulator) ->
    {ok, lists:reverse(Accumulator)};
parse_checksum_files([Entry | Rest], Seen, Accumulator)
        when is_map(Entry), map_size(Entry) =:= 2 ->
    Path = maps:get(<<"path">>, Entry, undefined),
    Digest = maps:get(<<"sha256">>, Entry, undefined),
    case is_binary(Path)
         andalso is_binary(Digest)
         andalso valid_sha256(Digest)
         andalso not maps:is_key(Path, Seen) of
        true ->
            parse_checksum_files(
                Rest,
                maps:put(Path, true, Seen),
                [Path | Accumulator]
            );
        false -> error
    end;
parse_checksum_files(_Files, _Seen, _Accumulator) -> error.

valid_sha256(Digest) when byte_size(Digest) =:= 64 ->
    lists:all(fun(Character) ->
        (Character >= $0 andalso Character =< $9)
        orelse (Character >= $a andalso Character =< $f)
    end, binary_to_list(Digest));
valid_sha256(_Digest) -> false.

checksums_json(Entries) ->
    Items = [
        [
            <<"{\"path\":\"">>,
            unicode:characters_to_binary(Name),
            <<"\",\"sha256\":\"">>,
            sha256_hex(Data),
            <<"\"}">>
        ]
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

ndjson([]) -> <<>>;
ndjson(Lines) -> iolist_to_binary([lists:join(<<"\n">>, Lines), <<"\n">>]).

split_ndjson(<<>>) -> [];
split_ndjson(Binary) ->
    [Line || Line <- binary:split(Binary, <<"\n">>, [global]), Line =/= <<>>].

error_binary(Term) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Term])).
