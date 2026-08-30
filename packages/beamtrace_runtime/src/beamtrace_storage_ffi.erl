%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_storage_ffi).

-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/zip.hrl").

-export([
    write_container/5,
    write_container_exclusive/5,
    read_container/1,
    read_window/3,
    search_container/4,
    decode_events_parallel/1,
    list_entries/1
]).

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
        ok -> write_container_file(Path, Manifest, EventLines, GraphSegments, Clocks, replace);
        {error, Reason} -> {error, error_binary({ensure_directory, Reason})}
    end;
write_container(_Path, _Manifest, _Events, _Graphs, _Clocks) ->
    {error, <<"invalid_container">>}.

write_container_exclusive(PathBinary, Manifest, EventLines, GraphSegments, Clocks)
        when is_binary(PathBinary), is_binary(Manifest), is_list(EventLines),
             is_list(GraphSegments), is_binary(Clocks) ->
    Path = unicode:characters_to_list(PathBinary),
    case filelib:ensure_dir(Path) of
        ok -> write_container_file(
            Path, Manifest, EventLines, GraphSegments, Clocks, exclusive
        );
        {error, Reason} -> {error, error_binary({ensure_directory, Reason})}
    end;
write_container_exclusive(_Path, _Manifest, _Events, _Graphs, _Clocks) ->
    {error, <<"invalid_container">>}.

write_container_file(Path, Manifest, EventLines, GraphSegments, Clocks, Mode) ->
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
                {ok, _} -> install_archive(Temporary, Path, Mode);
                {error, ZipReason} ->
                    _ = file:delete(Temporary),
                    {error, error_binary({zip_create, ZipReason})}
            end
    end.

install_archive(Temporary, Path, replace) -> atomic_replace(Temporary, Path);
install_archive(Temporary, Path, exclusive) -> atomic_install(Temporary, Path).

%% A hard-link claims the final name without a check-then-write race. The
%% temporary ZIP lives beside the destination, so both names share a volume.
atomic_install(Temporary, Path) ->
    _ = sync_file(Temporary),
    case file:make_link(Temporary, Path) of
        ok ->
            _ = file:delete(Temporary),
            {ok, nil};
        {error, eexist} ->
            _ = file:delete(Temporary),
            {error, <<"destination_exists">>};
        {error, Reason} ->
            _ = file:delete(Temporary),
            {error, error_binary({atomic_install, Reason})}
    end.

%% Use the OTP file server's replace operation on every supported target. We
%% deliberately do not unlink the destination first: any failure leaves the
%% previous archive intact. Other OS processes can observe an intermediate
%% rename step on Windows, as documented by OTP, but BeamTrace readers cannot.
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
    index_json_counts(Version, [
        {Name, length(split_ndjson(Data))}
        || {Name, Data} <- EventEntries
    ]).

index_json_counts(Version, EventCounts) ->
    {Items, _NextFirst} = lists:mapfoldl(fun({Name, Count}, First) ->
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
    end, 0, EventCounts),
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

%% Schema-v2 browsing validates the central directory and archive metadata,
%% then inflates only the event segments intersecting the requested window.
%% V1 requires global timestamp normalization and explicitly falls back to the
%% full reader in Gleam.
read_window(PathBinary, Start, Limit)
        when is_binary(PathBinary), is_integer(Start), Start >= 0,
             is_integer(Limit), Limit >= 1, Limit =< ?SEGMENT_EVENTS ->
    with_validated_handle(PathBinary, fun(Handle, Files) ->
        case prepare_selective_v2(Handle, Files) of
            {ok, Selection} -> select_window(Handle, Selection, Start, Limit);
            Error -> Error
        end
    end);
read_window(_Path, _Start, _Limit) -> {error, <<"invalid_window">>}.

%% Search verifies and scans one canonical event segment at a time. Only the
%% requested page of matching event lines is retained.
search_container(PathBinary, Query, Start, Limit)
        when is_binary(PathBinary), is_binary(Query), byte_size(Query) > 0,
             is_integer(Start), Start >= 0, is_integer(Limit), Limit >= 1,
             Limit =< ?SEGMENT_EVENTS ->
    with_validated_handle(PathBinary, fun(Handle, Files) ->
        case prepare_selective_v2(Handle, Files) of
            {ok, Selection} ->
                search_segments(Handle, Selection, Query, Start, Limit);
            Error -> Error
        end
    end);
search_container(_Path, _Query, _Start, _Limit) ->
    {error, <<"invalid_search">>}.

%% Full archive event lines are independent. Decode contiguous chunks on the
%% available schedulers, then join results (or select the first error) in input
%% order. Bounded window/search paths stay serial to avoid process overhead.
decode_events_parallel([]) -> {ok, []};
decode_events_parallel(Lines) when is_list(Lines) ->
    Length = length(Lines),
    SchedulerCount = erlang:min(8, erlang:system_info(schedulers_online)),
    WorkerCount = erlang:min(
        SchedulerCount,
        erlang:max(1, (Length + ?SEGMENT_EVENTS - 1) div ?SEGMENT_EVENTS)
    ),
    case WorkerCount of
        1 -> decode_event_lines(Lines, []);
        _ ->
            ChunkSize = (Length + WorkerCount - 1) div WorkerCount,
            Chunks = event_decode_chunks(Lines, ChunkSize, 1, []),
            decode_event_chunks(Chunks)
    end;
decode_events_parallel(_Lines) ->
    {error, {invalid_json, <<"parallel event decoder received invalid input">>}}.

event_decode_chunks([], _ChunkSize, _Index, Accumulator) ->
    lists:reverse(Accumulator);
event_decode_chunks(Lines, ChunkSize, Index, Accumulator) ->
    {Chunk, Rest} = take_lines(Lines, ChunkSize, []),
    event_decode_chunks(
        Rest, ChunkSize, Index + 1, [{Index, Chunk} | Accumulator]
    ).

decode_event_chunks(Chunks) ->
    Parent = self(),
    Reference = make_ref(),
    {IndexMonitors, MonitorIndexes} = spawn_event_decode_workers(
        Chunks, Parent, Reference, #{}, #{}
    ),
    collect_event_chunks(
        Reference,
        length(Chunks),
        IndexMonitors,
        MonitorIndexes,
        #{},
        length(Chunks)
    ).

spawn_event_decode_workers([], _Parent, _Reference, ByIndex, ByMonitor) ->
    {ByIndex, ByMonitor};
spawn_event_decode_workers(
        [{Index, Chunk} | Rest], Parent, Reference, ByIndex, ByMonitor
    ) ->
    {Pid, Monitor} = spawn_monitor(fun() ->
        Parent ! {Reference, Index, decode_event_lines(Chunk, [])}
    end),
    spawn_event_decode_workers(
        Rest,
        Parent,
        Reference,
        maps:put(Index, {Pid, Monitor}, ByIndex),
        maps:put(Monitor, {Index, Pid}, ByMonitor)
    ).

decode_event_lines([], Accumulator) ->
    {ok, lists:reverse(Accumulator)};
decode_event_lines([Line | Rest], Accumulator) ->
    case 'beamtrace@codec':decode_event(Line) of
        {ok, Event} -> decode_event_lines(Rest, [Event | Accumulator]);
        {error, _} = Error -> Error
    end.

collect_event_chunks(
        _Reference, 0, _ByIndex, _ByMonitor, Results, Count
    ) ->
    join_event_chunks(1, Count, Results, []);
collect_event_chunks(
        Reference, Remaining, ByIndex, ByMonitor, Results, Count
    ) ->
    receive
        {Reference, Index, Result} ->
            {_Pid, Monitor} = maps:get(Index, ByIndex),
            _ = erlang:demonitor(Monitor, [flush]),
            collect_event_chunks(
                Reference,
                Remaining - 1,
                maps:remove(Index, ByIndex),
                maps:remove(Monitor, ByMonitor),
                maps:put(Index, Result, Results),
                Count
            );
        {'DOWN', Monitor, process, _Pid, Reason}
                when is_map_key(Monitor, ByMonitor) ->
            stop_event_decode_workers(ByIndex),
            {error, {invalid_json,
                unicode:characters_to_binary(io_lib:format(
                    "parallel event decoder failed: ~0p", [Reason]
                ))}}
    end.

stop_event_decode_workers(ByIndex) ->
    lists:foreach(fun({_Index, {Pid, Monitor}}) ->
        _ = erlang:exit(Pid, kill),
        _ = erlang:demonitor(Monitor, [flush])
    end, maps:to_list(ByIndex)).

join_event_chunks(Index, Count, _Results, Chunks) when Index > Count ->
    {ok, lists:append(lists:reverse(Chunks))};
join_event_chunks(Index, Count, Results, Chunks) ->
    case maps:get(Index, Results) of
        {ok, Events} ->
            join_event_chunks(Index + 1, Count, Results, [Events | Chunks]);
        {error, _} = Error -> Error
    end.

with_validated_handle(PathBinary, Fun) ->
    Path = unicode:characters_to_list(PathBinary),
    case zip:zip_open(Path, [memory]) of
        {ok, Handle} ->
            try
                case zip:zip_list_dir(Handle) of
                    {ok, Entries} ->
                        Files = [Entry || Entry <- Entries,
                                          is_record(Entry, zip_file)],
                        case validate_files(Files) of
                            {ok, Validated} -> Fun(Handle, Validated);
                            Error -> Error
                        end;
                    {error, _Reason} -> {error, <<"invalid_container">>}
                end
            catch
                _:_ -> {error, <<"invalid_container">>}
            after
                _ = zip:zip_close(Handle)
            end;
        {error, _Reason} -> {error, <<"invalid_container">>}
    end.

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

prepare_selective_v2(Handle, Files) ->
    Names = [unicode:characters_to_binary(File#zip_file.name) || File <- Files],
    NamesMap = maps:from_list([{Name, true} || Name <- Names]),
    case read_handle_entry(Handle, <<"manifest.json">>) of
        {error, _} = Error -> Error;
        {ok, Manifest} ->
            case manifest_schema(Manifest) of
                {ok, 1} -> {error, <<"legacy_fallback">>};
                {ok, 2} ->
                    prepare_selective_v2_entries(
                        Handle, NamesMap, Manifest
                    );
                {ok, Version} ->
                    {error, <<"unknown_schema_version:",
                              (integer_to_binary(Version))/binary>>};
                error -> {error, <<"invalid_container">>}
            end
    end.

prepare_selective_v2_entries(Handle, NamesMap, Manifest) ->
    case {
        canonical_segments(NamesMap, <<"events/">>, <<".ndjson">>),
        canonical_segments(NamesMap, <<"graph/">>, <<".json">>)
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
            case exact_entries(NamesMap, DataNames) of
                false -> {error, <<"invalid_container">>};
                true ->
                    prepare_selective_metadata(
                        Handle, Manifest, EventNames, DataNames
                    )
            end;
        _ -> {error, <<"invalid_container">>}
    end.

prepare_selective_metadata(
        Handle, Manifest, EventNames, DataNames
    ) ->
    case read_handle_entries(Handle, [
        <<"indexes/events.idx">>,
        <<"checksums.json">>,
        <<"annotations.json">>,
        <<"clocks.json">>
    ], #{}) of
        {error, _} = Error -> Error;
        {ok, Metadata} ->
            Index = maps:get(<<"indexes/events.idx">>, Metadata),
            Checksums = maps:get(<<"checksums.json">>, Metadata),
            Annotations = maps:get(<<"annotations.json">>, Metadata),
            Clocks = maps:get(<<"clocks.json">>, Metadata),
            case {
                parse_canonical_index(Index, EventNames),
                parse_selective_checksums(Checksums, DataNames)
            } of
                {{ok, Segments, Total}, {ok, Digests}}
                        when Annotations =:=
                             <<"{\"schema_version\":2,\"annotations\":[]}">> ->
                    Selected = [
                        {<<"manifest.json">>, Manifest},
                        {<<"indexes/events.idx">>, Index},
                        {<<"annotations.json">>, Annotations},
                        {<<"clocks.json">>, Clocks}
                    ],
                    case verify_selected_entries(Selected, Digests) of
                        ok ->
                            {ok, #{
                                manifest => Manifest,
                                clocks => Clocks,
                                segments => Segments,
                                total => Total,
                                digests => Digests
                            }};
                        Error -> Error
                    end;
                {{error, _} = Error, _} -> Error;
                {_, {error, _} = Error} -> Error;
                _ -> {error, <<"invalid_container">>}
            end
    end.

read_handle_entries(_Handle, [], Accumulator) -> {ok, Accumulator};
read_handle_entries(Handle, [Name | Rest], Accumulator) ->
    case read_handle_entry(Handle, Name) of
        {ok, Data} ->
            read_handle_entries(
                Handle, Rest, maps:put(Name, Data, Accumulator)
            );
        Error -> Error
    end.

read_handle_entry(Handle, Name) ->
    case zip:zip_get(Name, Handle) of
        {ok, {_ReturnedName, Data}} when is_binary(Data) -> {ok, Data};
        {error, _Reason} -> {error, <<"invalid_container">>};
        _ -> {error, <<"invalid_container">>}
    end.

parse_canonical_index(Source, EventNames) ->
    try json:decode(Source) of
        Object when is_map(Object), map_size(Object) =:= 2 ->
            case {
                maps:get(<<"schema_version">>, Object, undefined),
                maps:get(<<"segments">>, Object, undefined)
            } of
                {2, Items} when is_list(Items) ->
                    case parse_index_segments(
                        Items, EventNames, 0, length(EventNames), []
                    ) of
                        {ok, Segments, Total} ->
                            case Source =:= index_json_segments(2, Segments) of
                                true -> {ok, Segments, Total};
                                false -> {error, <<"invalid_container">>}
                            end;
                        error -> {error, <<"invalid_container">>}
                    end;
                _ -> {error, <<"invalid_container">>}
            end;
        _ -> {error, <<"invalid_container">>}
    catch
        _:_ -> {error, <<"invalid_container">>}
    end.

parse_index_segments([], [], First, _Total, Accumulator) ->
    {ok, lists:reverse(Accumulator), First};
parse_index_segments(
        [Item | Rest], [ExpectedName | RestNames], First, Total, Accumulator
    ) when is_map(Item), map_size(Item) =:= 3 ->
    Path = maps:get(<<"path">>, Item, undefined),
    EncodedFirst = maps:get(<<"first">>, Item, undefined),
    Count = maps:get(<<"count">>, Item, undefined),
    Position = Total - length(RestNames),
    ValidCount = is_integer(Count)
        andalso Count >= 0
        andalso Count =< ?SEGMENT_EVENTS
        andalso (Position =:= Total orelse Count =:= ?SEGMENT_EVENTS),
    case Path =:= ExpectedName
         andalso EncodedFirst =:= First
         andalso ValidCount of
        true ->
            parse_index_segments(
                Rest,
                RestNames,
                First + Count,
                Total,
                [{Path, First, Count} | Accumulator]
            );
        false -> error
    end;
parse_index_segments(_Items, _Names, _First, _Total, _Accumulator) -> error.

index_json_segments(Version, Segments) ->
    Items = [
        [
            <<"{\"path\":\"">>, Path,
            <<"\",\"first\":">>, integer_to_binary(First),
            <<",\"count\":">>, integer_to_binary(Count), <<"}">>
        ]
        || {Path, First, Count} <- Segments
    ],
    iolist_to_binary([
        <<"{\"schema_version\":" >>,
        integer_to_binary(Version),
        <<",\"segments\":[">>,
        lists:join(<<",">>, Items),
        <<"]}">>
    ]).

parse_selective_checksums(Source, ExpectedNames) ->
    try json:decode(Source) of
        Object when is_map(Object), map_size(Object) =:= 2 ->
            case {
                maps:get(<<"algorithm">>, Object, undefined),
                maps:get(<<"files">>, Object, undefined)
            } of
                {<<"sha256">>, Files} when is_list(Files) ->
                    case parse_selective_checksum_files(
                        Files, ExpectedNames, #{}, []
                    ) of
                        {ok, Digests, Ordered} ->
                            case Source =:= checksum_inventory_json(Ordered) of
                                true -> {ok, Digests};
                                false -> {error, <<"invalid_checksums">>}
                            end;
                        error -> {error, <<"invalid_checksums">>}
                    end;
                _ -> {error, <<"invalid_checksums">>}
            end;
        _ -> {error, <<"invalid_checksums">>}
    catch
        _:_ -> {error, <<"invalid_checksums">>}
    end.

parse_selective_checksum_files([], [], Digests, Accumulator) ->
    {ok, Digests, lists:reverse(Accumulator)};
parse_selective_checksum_files(
        [Entry | Rest], [Expected | RestExpected], Digests, Accumulator
    ) when is_map(Entry), map_size(Entry) =:= 2 ->
    Path = maps:get(<<"path">>, Entry, undefined),
    Digest = maps:get(<<"sha256">>, Entry, undefined),
    case Path =:= Expected andalso valid_sha256(Digest) of
        true ->
            parse_selective_checksum_files(
                Rest,
                RestExpected,
                maps:put(Path, Digest, Digests),
                [{Path, Digest} | Accumulator]
            );
        false -> error
    end;
parse_selective_checksum_files(
        _Files, _Expected, _Digests, _Accumulator
    ) -> error.

checksum_inventory_json(Files) ->
    Items = [
        [
            <<"{\"path\":\"">>, Path,
            <<"\",\"sha256\":\"">>, Digest, <<"\"}">>
        ]
        || {Path, Digest} <- Files
    ],
    iolist_to_binary([
        <<"{\"algorithm\":\"sha256\",\"files\":[">>,
        lists:join(<<",">>, Items),
        <<"]}">>
    ]).

verify_selected_entries([], _Digests) -> ok;
verify_selected_entries([{Name, Data} | Rest], Digests) ->
    case maps:find(Name, Digests) of
        {ok, Digest} ->
            case sha256_hex(Data) =:= Digest of
                true -> verify_selected_entries(Rest, Digests);
                false -> {error, <<"checksum_mismatch">>}
            end;
        error -> {error, <<"invalid_checksums">>}
    end.

select_window(Handle, Selection, Start, Limit) ->
    Segments = maps:get(segments, Selection),
    Digests = maps:get(digests, Selection),
    End = Start + Limit,
    SelectedSegments = [
        Segment
        || Segment = {_Name, First, Count} <- Segments,
           First < End,
           First + Count > Start
    ],
    case window_segment_lines(
        Handle, SelectedSegments, Digests, Start, End, []
    ) of
        {ok, ReversedLines} ->
            {ok, {
                maps:get(manifest, Selection),
                lists:reverse(ReversedLines),
                maps:get(clocks, Selection),
                maps:get(total, Selection)
            }};
        Error -> Error
    end.

window_segment_lines(
        _Handle, [], _Digests, _Start, _End, Accumulator
    ) -> {ok, Accumulator};
window_segment_lines(
        Handle,
        [Segment = {_Name, First, Count} | Rest],
        Digests,
        Start,
        End,
        Accumulator
    ) ->
    case read_verified_event_segment(Handle, Segment, Digests) of
        {ok, Lines} ->
            LocalStart = erlang:max(Start, First) - First,
            LocalEnd = erlang:min(End, First + Count) - First,
            Selected = lists:sublist(
                lists:nthtail(LocalStart, Lines), LocalEnd - LocalStart
            ),
            window_segment_lines(
                Handle,
                Rest,
                Digests,
                Start,
                End,
                lists:reverse(Selected, Accumulator)
            );
        Error -> Error
    end.

search_segments(Handle, Selection, Query, Start, Limit) ->
    End = Start + Limit,
    case search_event_segments(
        Handle,
        maps:get(segments, Selection),
        maps:get(digests, Selection),
        Query,
        Start,
        End,
        0,
        []
    ) of
        {ok, MatchCount, ReversedLines} ->
            {ok, {
                maps:get(manifest, Selection),
                lists:reverse(ReversedLines),
                maps:get(clocks, Selection),
                MatchCount
            }};
        Error -> Error
    end.

search_event_segments(
        _Handle, [], _Digests, _Query, _Start, _End, MatchCount, Selected
    ) -> {ok, MatchCount, Selected};
search_event_segments(
        Handle,
        [Segment | Rest],
        Digests,
        Query,
        Start,
        End,
        MatchCount,
        Selected
    ) ->
    case read_verified_event_segment(Handle, Segment, Digests) of
        {ok, Lines} ->
            {NextCount, NextSelected} = search_event_lines(
                Lines, Query, Start, End, MatchCount, Selected
            ),
            search_event_segments(
                Handle,
                Rest,
                Digests,
                Query,
                Start,
                End,
                NextCount,
                NextSelected
            );
        Error -> Error
    end.

search_event_lines([], _Query, _Start, _End, MatchCount, Selected) ->
    {MatchCount, Selected};
search_event_lines(
        [Line | Rest], Query, Start, End, MatchCount, Selected
    ) ->
    case binary:match(string:lowercase(Line), Query) of
        nomatch ->
            search_event_lines(
                Rest, Query, Start, End, MatchCount, Selected
            );
        {_Position, _Length} ->
            NextSelected = case MatchCount >= Start andalso MatchCount < End of
                true -> [Line | Selected];
                false -> Selected
            end,
            search_event_lines(
                Rest,
                Query,
                Start,
                End,
                MatchCount + 1,
                NextSelected
            )
    end.

read_verified_event_segment(
        Handle, {Name, _First, ExpectedCount}, Digests
    ) ->
    case read_handle_entry(Handle, Name) of
        {ok, Data} ->
            case verify_selected_entries([{Name, Data}], Digests) of
                ok ->
                    Lines = split_ndjson(Data),
                    case length(Lines) =:= ExpectedCount
                         andalso Data =:= ndjson(Lines) of
                        true -> {ok, Lines};
                        false -> {error, <<"invalid_container">>}
                    end;
                Error -> Error
            end;
        Error -> Error
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
                 andalso maps:get(<<"processes.ndjson">>, ByName, invalid) =:= <<>>
                 andalso maps:get(<<"annotations.json">>, ByName, invalid) =:= <<"[]">> of
                false -> {error, <<"invalid_container">>};
                true ->
                    case validated_event_segments(ByName, EventNames) of
                        {error, _} = Error -> Error;
                        {ok, EventSegments} ->
                            decode_v1_segments(
                                Manifest,
                                ByName,
                                DataNames,
                                EventSegments
                            )
                    end
            end
    end.

decode_v1_segments(Manifest, ByName, DataNames, EventSegments) ->
    Counts = [{Name, Count} || {Name, Count, _Lines} <- EventSegments],
    case maps:get(<<"indexes/events.idx">>, ByName, invalid)
         =:= index_json_counts(1, Counts) of
        false -> {error, <<"invalid_container">>};
        true ->
            case verify_all_checksums(ByName, DataNames) of
                ok ->
                    Events = lists:append([
                        Lines || {_Name, _Count, Lines} <- EventSegments
                    ]),
                    {ok, {Manifest, Events, [], <<>>}};
                Error -> Error
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
                 andalso maps:get(<<"annotations.json">>, ByName, invalid)
                     =:= <<"{\"schema_version\":2,\"annotations\":[]}">> of
                false -> {error, <<"invalid_container">>};
                true ->
                    case validated_event_segments(ByName, EventNames) of
                        {error, _} = Error -> Error;
                        {ok, EventSegments} ->
                            decode_v2_segments(
                                Manifest,
                                ByName,
                                DataNames,
                                GraphNames,
                                EventSegments
                            )
                    end
            end;
        _ -> {error, <<"invalid_container">>}
    end.

decode_v2_segments(
        Manifest, ByName, DataNames, GraphNames, EventSegments
    ) ->
    Counts = [{Name, Count} || {Name, Count, _Lines} <- EventSegments],
    case maps:get(<<"indexes/events.idx">>, ByName, invalid)
         =:= index_json_counts(2, Counts) of
        false -> {error, <<"invalid_container">>};
        true ->
            case verify_all_checksums(ByName, DataNames) of
                ok ->
                    Events = lists:append([
                        Lines || {_Name, _Count, Lines} <- EventSegments
                    ]),
                    Graphs = [maps:get(Name, ByName) || Name <- GraphNames],
                    Clocks = maps:get(<<"clocks.json">>, ByName),
                    {ok, {Manifest, Events, Graphs, Clocks}};
                Error -> Error
            end
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

validated_event_segments(ByName, Names) ->
    validated_event_segments(ByName, Names, 1, length(Names), []).

validated_event_segments(_ByName, [], _Position, _Total, Accumulator) ->
    {ok, lists:reverse(Accumulator)};
validated_event_segments(
        ByName, [Name | Rest], Position, Total, Accumulator
    ) ->
    Data = maps:get(Name, ByName),
    Lines = split_ndjson(Data),
    Count = length(Lines),
    CanonicalCount = case Position < Total of
        true -> Count =:= ?SEGMENT_EVENTS;
        false -> Count >= 0 andalso Count =< ?SEGMENT_EVENTS
    end,
    case CanonicalCount andalso Data =:= ndjson(Lines) of
        true ->
            validated_event_segments(
                ByName,
                Rest,
                Position + 1,
                Total,
                [{Name, Count, Lines} | Accumulator]
            );
        false -> {error, <<"invalid_container">>}
    end.

exact_entries(ByName, DataNames) ->
    Actual = lists:sort(maps:keys(ByName)),
    Expected = lists:sort([<<"checksums.json">> | DataNames]),
    Actual =:= Expected.

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
