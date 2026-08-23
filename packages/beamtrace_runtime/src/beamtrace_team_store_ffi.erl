%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_team_store_ffi).

-include_lib("kernel/include/file.hrl").

-export([prepare_data_paths/1]).

-define(MAX_PATH_BYTES, 4096).

prepare_data_paths(DataDir)
        when is_binary(DataDir), byte_size(DataDir) > 0,
             byte_size(DataDir) =< ?MAX_PATH_BYTES ->
    case binary:match(DataDir, <<0>>) of
        nomatch -> prepare_valid_data_paths(DataDir);
        _ -> {error, <<"invalid_data_dir">>}
    end;
prepare_data_paths(_DataDir) ->
    {error, <<"invalid_data_dir">>}.

prepare_valid_data_paths(DataDir) ->
    try
        Absolute = filename:absname(unicode:characters_to_list(DataDir)),
        Database = filename:join(Absolute, "metadata.sqlite3"),
        BlobRoot = filename:join(Absolute, "blobs"),
        case ensure_real_directory(Absolute) of
            ok ->
                case ensure_database_target(Database) of
                    ok ->
                        case ensure_real_directory(BlobRoot) of
                            ok -> {ok, {
                                normalized_path(Database),
                                normalized_path(BlobRoot)
                            }};
                            Error -> Error
                        end;
                    Error -> Error
                end;
            Error -> Error
        end
    catch
        _:_ -> {error, <<"invalid_data_dir">>}
    end.

ensure_real_directory(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> ok;
        {ok, _Info} -> {error, <<"unsafe_data_path">>};
        {error, enoent} ->
            case filelib:ensure_dir(filename:join(Path, ".beamtrace")) of
                ok ->
                    case file:read_link_info(Path) of
                        {ok, #file_info{type = directory}} -> ok;
                        _ -> {error, <<"unsafe_data_path">>}
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

ensure_database_target(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} -> ok;
        {ok, _Info} -> {error, <<"unsafe_database_path">>};
        {error, enoent} -> ok;
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

normalized_path(Path) ->
    binary:replace(
        unicode:characters_to_binary(Path),
        <<"\\">>,
        <<"/">>,
        [global]
    ).

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
