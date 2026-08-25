%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_project_config_ffi).

-include_lib("kernel/include/file.hrl").

-export([load/0, init/1, resolve_path/2]).

load() ->
    Path = filename:absname("beamtrace.toml"),
    case file:read_link_info(Path) of
        {error, enoent} -> {ok, none};
        {ok, #file_info{type = regular}} ->
            case file:read_file(Path) of
                {ok, Contents} -> {ok, {some, {
                    unicode:characters_to_binary(Path), Contents
                }}};
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {ok, _} -> {error, <<"beamtrace.toml must be a regular file">>};
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

init(Contents) when is_binary(Contents) ->
    Path = filename:absname("beamtrace.toml"),
    case file:open(Path, [write, binary, exclusive, {mode, 8#644}]) of
        {ok, File} ->
            Result = file:write(File, Contents),
            Close = file:close(File),
            case {Result, Close} of
                {ok, ok} -> {ok, unicode:characters_to_binary(Path)};
                {{error, Reason}, _} -> {error, reason_binary(Reason)};
                {_, {error, Reason}} -> {error, reason_binary(Reason)}
            end;
        {error, eexist} -> {error, <<"beamtrace.toml already exists">>};
        {error, Reason} -> {error, reason_binary(Reason)}
    end;
init(_Contents) -> {error, <<"invalid project configuration">>}.

resolve_path(ConfigPath, Value) when is_binary(ConfigPath), is_binary(Value) ->
    try
        Path = unicode:characters_to_list(Value),
        Resolved = case filename:pathtype(Path) of
            absolute -> filename:absname(Path);
            _ -> filename:absname(Path, filename:dirname(
                unicode:characters_to_list(ConfigPath)
            ))
        end,
        {ok, unicode:characters_to_binary(Resolved)}
    catch
        _:_ -> {error, <<"invalid configuration path">>}
    end.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
