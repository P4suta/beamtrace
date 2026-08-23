%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_storage_ffi).

-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/zip.hrl").

-export([
    write_container/3,
    read_container/1,
    read_window/3,
    search_archive/4,
    list_entries/1
]).

-define(MAX_ENTRIES, 10000).
-define(MAX_UNCOMPRESSED_BYTES, 1073741824).
-define(MAX_COMPRESSION_RATIO, 200).
-define(MAX_ENTRY_BYTES, 67108864).
-define(SEGMENT_EVENTS, 1000).

write_container(PathBinary, Manifest, EventLines)
        when is_binary(PathBinary), is_binary(Manifest), is_list(EventLines) ->
    Path = unicode:characters_to_list(PathBinary),
    case filelib:ensure_dir(Path) of
        ok -> write_container_file(Path, Manifest, EventLines);
        {error, Reason} -> {error, error_binary({ensure_directory, Reason})}
    end.

write_container_file(Path, Manifest, EventLines) ->
    EventEntries = event_entries(EventLines),
    Processes = <<>>,
    Annotations = <<"[]">>,
    Index = index_json(EventEntries),
    DataEntries = [
        {"manifest.json", Manifest}
    ] ++ EventEntries ++ [
        {"processes.ndjson", Processes},
        {"annotations.json", Annotations},
        {"indexes/events.idx", Index}
    ],
    Checksums = checksums_json(DataEntries),
    Entries = DataEntries ++ [{"checksums.json", Checksums}],
    Temporary = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    case zip:create(Temporary, Entries, []) of
        {ok, _} ->
            _ = file:delete(Path),
            case file:rename(Temporary, Path) of
                ok -> {ok, nil};
                {error, Reason} ->
                    _ = file:delete(Temporary),
                    {error, error_binary({rename, Reason})}
            end;
        {error, Reason} ->
            _ = file:delete(Temporary),
            {error, error_binary({zip_create, Reason})}
    end.

event_entries([]) -> [{"events/000001.ndjson", <<>>}];
event_entries(EventLines) -> event_entries(EventLines, 1, []).

event_entries([], _Sequence, Accumulator) -> lists:reverse(Accumulator);
event_entries(EventLines, Sequence, Accumulator) ->
    {Chunk, Rest} = take_lines(EventLines, ?SEGMENT_EVENTS, []),
    Name = lists:flatten(io_lib:format("events/~6..0B.ndjson", [Sequence])),
    event_entries(Rest, Sequence + 1, [{Name, ndjson(Chunk)} | Accumulator]).

take_lines(Rest, 0, Accumulator) -> {lists:reverse(Accumulator), Rest};
take_lines([], _Remaining, Accumulator) -> {lists:reverse(Accumulator), []};
take_lines([Line | Rest], Remaining, Accumulator) ->
    take_lines(Rest, Remaining - 1, [Line | Accumulator]).

index_json(EventEntries) ->
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
        <<"{\"schema_version\":1,\"segments\":[">>,
        lists:join(<<",">>, Items),
        <<"]}">>
    ]).

read_container(PathBinary) when is_binary(PathBinary) ->
    Path = unicode:characters_to_list(PathBinary),
    case validated_table(Path) of
        {ok, _Files} ->
            case zip:extract(Path, [memory]) of
                {ok, Extracted} -> decode_extracted(Extracted);
                {error, _Reason} -> {error, <<"invalid_container">>}
            end;
        Error -> Error
    end.

list_entries(PathBinary) when is_binary(PathBinary) ->
    Path = unicode:characters_to_list(PathBinary),
    case validated_table(Path) of
        {ok, Files} ->
            {ok, [unicode:characters_to_binary(File#zip_file.name) || File <- Files]};
        Error -> Error
    end.

read_window(PathBinary, Start, Limit)
        when is_binary(PathBinary), is_integer(Start), is_integer(Limit),
             Start >= 0, Limit >= 1, Limit =< 1000 ->
    Path = unicode:characters_to_list(PathBinary),
    case validated_table(Path) of
        {ok, Files} -> read_window_files(Path, Files, Start, Limit);
        Error -> Error
    end;
read_window(_PathBinary, _Start, _Limit) ->
    {error, <<"invalid_window">>}.

search_archive(PathBinary, Query, Start, Limit)
        when is_binary(PathBinary), is_binary(Query), is_integer(Start),
             is_integer(Limit), byte_size(Query) > 0, byte_size(Query) =< 256,
             Start >= 0, Limit >= 1, Limit =< 1000 ->
    Path = unicode:characters_to_list(PathBinary),
    case fold_text(Query) of
        {ok, FoldedQuery} ->
            case validated_table(Path) of
                {ok, Files} ->
                    case canonical_event_names(Files) of
                        {ok, EventNames} ->
                            search_event_names(
                                Path,
                                EventNames,
                                FoldedQuery,
                                Start,
                                Limit,
                                0,
                                0,
                                []
                            );
                        Error -> Error
                    end;
                Error -> Error
            end;
        error -> {error, <<"invalid_search">>}
    end;
search_archive(_PathBinary, _Query, _Start, _Limit) ->
    {error, <<"invalid_search">>}.

search_event_names(
    _Path,
    [],
    _Query,
    _Start,
    _Limit,
    MatchCount,
    _CollectedCount,
    Accumulator
) ->
    {ok, {lists:reverse(Accumulator), MatchCount}};
search_event_names(
    Path,
    [Name | Rest],
    Query,
    Start,
    Limit,
    MatchCount,
    CollectedCount,
    Accumulator
) ->
    case extract_verified(Path, [Name]) of
        {ok, ByName} ->
            case search_lines(
                data_lines(Name, ByName),
                Query,
                Start,
                Limit,
                MatchCount,
                CollectedCount,
                Accumulator
            ) of
                {ok, {NextMatchCount, NextCollectedCount, NextAccumulator}} ->
                    search_event_names(
                        Path,
                        Rest,
                        Query,
                        Start,
                        Limit,
                        NextMatchCount,
                        NextCollectedCount,
                        NextAccumulator
                    );
                Error -> Error
            end;
        Error -> Error
    end.

search_lines([], _Query, _Start, _Limit, MatchCount, CollectedCount, Accumulator) ->
    {ok, {MatchCount, CollectedCount, Accumulator}};
search_lines(
    [Line | Rest], Query, Start, Limit, MatchCount, CollectedCount, Accumulator
) ->
    case fold_text(Line) of
        error -> {error, <<"invalid_container">>};
        {ok, FoldedLine} ->
            case binary:match(FoldedLine, Query) of
                nomatch ->
                    search_lines(
                        Rest,
                        Query,
                        Start,
                        Limit,
                        MatchCount,
                        CollectedCount,
                        Accumulator
                    );
                _Match ->
                    Include = MatchCount >= Start andalso CollectedCount < Limit,
                    NextAccumulator = case Include of
                        true -> [Line | Accumulator];
                        false -> Accumulator
                    end,
                    NextCollectedCount = case Include of
                        true -> CollectedCount + 1;
                        false -> CollectedCount
                    end,
                    search_lines(
                        Rest,
                        Query,
                        Start,
                        Limit,
                        MatchCount + 1,
                        NextCollectedCount,
                        NextAccumulator
                    )
            end
    end.

fold_text(Binary) ->
    try
        Characters = unicode:characters_to_list(Binary),
        {ok, unicode:characters_to_binary(string:casefold(Characters))}
    catch
        _:_ -> error
    end.

read_window_files(Path, Files, Start, Limit) ->
    case canonical_event_names(Files) of
        {ok, EventNames} ->
            LastName = lists:last(EventNames),
            case extract_verified(Path, [LastName]) of
                {ok, LastByName} ->
                    LastLines = data_lines(LastName, LastByName),
                    Total = (length(EventNames) - 1) * ?SEGMENT_EVENTS + length(LastLines),
                    read_requested_window(Path, EventNames, Start, Limit, Total);
                Error -> Error
            end;
        Error -> Error
    end.

read_requested_window(_Path, _EventNames, Start, _Limit, Total) when Start >= Total ->
    {ok, {[], Total}};
read_requested_window(Path, EventNames, Start, Limit, Total) ->
    EndExclusive = erlang:min(Start + Limit, Total),
    FirstSegment = Start div ?SEGMENT_EVENTS + 1,
    LastSegment = (EndExclusive - 1) div ?SEGMENT_EVENTS + 1,
    RequestedNames = lists:sublist(
        EventNames,
        FirstSegment,
        LastSegment - FirstSegment + 1
    ),
    case extract_verified(Path, RequestedNames) of
        {ok, ByName} ->
            Lines = lists:append([data_lines(Name, ByName) || Name <- RequestedNames]),
            Offset = Start rem ?SEGMENT_EVENTS,
            Window = lists:sublist(drop_lines(Offset, Lines), EndExclusive - Start),
            {ok, {Window, Total}};
        Error -> Error
    end.

canonical_event_names(Files) ->
    Names = lists:sort([
        File#zip_file.name || File <- Files,
            is_event_segment(unicode:characters_to_binary(File#zip_file.name))
    ]),
    Expected = [
        lists:flatten(io_lib:format("events/~6..0B.ndjson", [Sequence]))
        || Sequence <- lists:seq(1, length(Names))
    ],
    case Names =/= [] andalso Names =:= Expected of
        true -> {ok, Names};
        false -> {error, <<"invalid_container">>}
    end.

extract_verified(Path, Names) ->
    Wanted = lists:usort(["checksums.json" | Names]),
    case zip:extract(Path, [memory, {file_list, Wanted}]) of
        {ok, Extracted} ->
            ByName = maps:from_list([
                {unicode:characters_to_binary(Name), Data}
                || {Name, Data} <- Extracted,
                   is_binary(Data)
            ]),
            case verify_checksums(ByName) of
                true -> {ok, ByName};
                false -> {error, <<"checksum_mismatch">>}
            end;
        {error, _Reason} -> {error, <<"invalid_container">>}
    end.

data_lines(Name, ByName) ->
    BinaryName = unicode:characters_to_binary(Name),
    split_ndjson(maps:get(BinaryName, ByName, <<>>)).

drop_lines(0, Lines) -> Lines;
drop_lines(_Count, []) -> [];
drop_lines(Count, [_ | Rest]) -> drop_lines(Count - 1, Rest).

validated_table(Path) ->
    case zip:table(Path) of
        {ok, Entries} ->
            Files = [Entry || Entry <- Entries, is_record(Entry, zip_file)],
            validate_files(Files);
        {error, _Reason} ->
            {error, <<"invalid_container">>}
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

validate_sizes(Files) ->
    Total = lists:sum([(File#zip_file.info)#file_info.size || File <- Files]),
    OversizedEntry = lists:any(fun(File) ->
        (File#zip_file.info)#file_info.size > ?MAX_ENTRY_BYTES
    end, Files),
    case Total > ?MAX_UNCOMPRESSED_BYTES orelse OversizedEntry orelse has_suspicious_ratio(Files) of
        true -> {error, <<"zip_bomb">>};
        false -> {ok, Files}
    end.

validate_names([]) -> ok;
validate_names([File | Rest]) ->
    Name = File#zip_file.name,
    case safe_entry_name(Name) of
        true -> validate_names(Rest);
        false -> {error, <<"unsafe_entry:", (unicode:characters_to_binary(Name))/binary>>}
    end.

validate_unique_names([], _Seen) -> ok;
validate_unique_names([File | Rest], Seen) ->
    Name = File#zip_file.name,
    case maps:is_key(Name, Seen) of
        true ->
            {error, <<"duplicate_entry:", (unicode:characters_to_binary(Name))/binary>>};
        false ->
            validate_unique_names(Rest, maps:put(Name, true, Seen))
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
            Compressed =:= 0 orelse Size div erlang:max(Compressed, 1) > ?MAX_COMPRESSION_RATIO
        )
    end, Files).

decode_extracted(Extracted) ->
    ByName = maps:from_list([
        {unicode:characters_to_binary(Name), Data}
        || {Name, Data} <- Extracted,
           is_binary(Data)
    ]),
    EventNames = lists:sort([
        Name || Name <- maps:keys(ByName),
            is_event_segment(Name)
    ]),
    case {maps:find(<<"manifest.json">>, ByName), EventNames} of
        {{ok, Manifest}, [_ | _]} ->
            case verify_checksums(ByName) of
                true ->
                    Events = lists:append([
                        split_ndjson(maps:get(Name, ByName)) || Name <- EventNames
                    ]),
                    {ok, {Manifest, Events}};
                false -> {error, <<"checksum_mismatch">>}
            end;
        _ ->
            {error, <<"invalid_container">>}
    end.

is_event_segment(Name) ->
    case Name of
        <<"events/", _/binary>> ->
            byte_size(Name) > byte_size(<<"events/.ndjson">>)
                andalso binary:part(Name, byte_size(Name) - 7, 7) =:= <<".ndjson">>;
        _ -> false
    end.

verify_checksums(ByName) ->
    case maps:find(<<"checksums.json">>, ByName) of
        error -> false;
        {ok, Checksums} ->
            maps:fold(fun(Name, Data, Valid) ->
                case Name =:= <<"checksums.json">> of
                    true -> Valid;
                    false ->
                        Digest = sha256_hex(Data),
                        Expected = iolist_to_binary([
                            <<"{\"path\":\"">>,
                            Name,
                            <<"\",\"sha256\":\"">>,
                            Digest,
                            <<"\"}">>
                        ]),
                        Valid andalso binary:match(Checksums, Expected) =/= nomatch
                end
            end, true, ByName)
    end.

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
    iolist_to_binary([<<"{\"algorithm\":\"sha256\",\"files\":[">>,
        lists:join(<<",">>, Items), <<"]}">>]).

sha256_hex(Data) ->
    Digest = crypto:hash(sha256, Data),
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>> || <<Byte>> <= Digest >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.

ndjson([]) -> <<>>;
ndjson(Lines) -> iolist_to_binary([lists:join(<<"\n">>, Lines), <<"\n">>]).

split_ndjson(<<>>) -> [];
split_ndjson(Binary) ->
    [Line || Line <- binary:split(Binary, <<"\n">>, [global]), Line =/= <<>>].

error_binary(Term) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Term])).
