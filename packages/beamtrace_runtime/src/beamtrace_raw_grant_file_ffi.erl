%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_raw_grant_file_ffi).

-export([read_bounded/1, read_bounded_wait/2]).

-include_lib("kernel/include/file.hrl").

-define(MAX_BYTES, 16384).

read_bounded(Path) when is_binary(Path), byte_size(Path) > 0 ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_BYTES ->
            case file:read_file(Path) of
                {ok, Content} when byte_size(Content) =< ?MAX_BYTES -> {ok, Content};
                _ -> {error, <<"invalid_raw_grant_file">>}
            end;
        _ -> {error, <<"invalid_raw_grant_file">>}
    end;
read_bounded(_) -> {error, <<"invalid_raw_grant_file">>}.

read_bounded_wait(Path, TimeoutMs)
        when is_binary(Path), is_integer(TimeoutMs), TimeoutMs > 0,
             TimeoutMs =< 300000 ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(Path, Deadline);
read_bounded_wait(_, _) -> {error, <<"invalid_raw_grant_file">>}.

wait_loop(Path, Deadline) ->
    case file:read_file_info(Path) of
        {error, enoent} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(100),
                    wait_loop(Path, Deadline);
                false -> {error, <<"raw_grant_file_timeout">>}
            end;
        _ -> read_bounded(Path)
    end.
