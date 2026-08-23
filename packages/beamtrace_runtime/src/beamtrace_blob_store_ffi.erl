%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_blob_store_ffi).

-include_lib("kernel/include/file.hrl").

-export([put/3, read/2, read_verified/4, delete/2]).

-define(MAX_PATH_BYTES, 4096).
-define(MAX_KEY_BYTES, 1024).
-define(MAX_BLOB_BYTES, 1048576).

put(Root, Key, Payload)
        when is_binary(Root), is_binary(Key), is_binary(Payload),
             byte_size(Payload) > 0,
             byte_size(Payload) =< ?MAX_BLOB_BYTES ->
    case validate_location(Root, Key) of
        {ok, Target} -> put_valid(Target, Key, Payload);
        Error -> Error
    end;
put(Root, Key, Payload) when is_binary(Root), is_binary(Key), is_binary(Payload) ->
    {error, <<"invalid_blob_payload">>};
put(_Root, _Key, _Payload) ->
    {error, <<"invalid_blob_payload">>}.

read(Root, Key) when is_binary(Root), is_binary(Key) ->
    case validate_location(Root, Key) of
        {ok, Target} -> read_regular_blob(Target);
        Error -> Error
    end;
read(_Root, _Key) ->
    {error, <<"invalid_blob_key">>}.

read_verified(Root, Key, ExpectedSha256, ExpectedBytes)
        when is_binary(ExpectedSha256), is_integer(ExpectedBytes),
             ExpectedBytes > 0, ExpectedBytes =< ?MAX_BLOB_BYTES ->
    case valid_sha256(ExpectedSha256) of
        false -> {error, <<"invalid_blob_checksum">>};
        true ->
            case read(Root, Key) of
                {ok, Payload} ->
                    ActualSha256 = hex(crypto:hash(sha256, Payload)),
                    case byte_size(Payload) =:= ExpectedBytes
                            andalso ActualSha256 =:= ExpectedSha256 of
                        true -> {ok, Payload};
                        false -> {error, <<"blob_checksum_mismatch">>}
                    end;
                Error -> Error
            end
    end;
read_verified(_Root, _Key, _ExpectedSha256, _ExpectedBytes) ->
    {error, <<"invalid_blob_checksum">>}.

delete(Root, Key) when is_binary(Root), is_binary(Key) ->
    case validate_location(Root, Key) of
        {ok, Target} ->
            case file:read_link_info(Target) of
                {ok, #file_info{type = regular}} ->
                    case file:delete(Target) of
                        ok -> {ok, nil};
                        {error, enoent} -> {ok, nil};
                        {error, Reason} -> {error, reason_binary(Reason)}
                    end;
                {ok, _Info} -> {error, <<"unsafe_blob_path">>};
                {error, enoent} -> {ok, nil};
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        Error -> Error
    end;
delete(_Root, _Key) ->
    {error, <<"invalid_blob_key">>}.

validate_location(Root, Key) ->
    case valid_root(Root) andalso valid_key(Key) of
        false -> {error, <<"invalid_blob_key">>};
        true ->
            try
                RootPath = filename:absname(unicode:characters_to_list(Root)),
                Segments = [unicode:characters_to_list(Segment)
                    || Segment <- binary:split(Key, <<"/">>, [global])],
                case ensure_real_directory(RootPath) of
                    ok ->
                        case ensure_parent_directories(RootPath, droplast(Segments)) of
                            {ok, Parent} ->
                                {ok, filename:join(Parent, lists:last(Segments))};
                            Error -> Error
                        end;
                    Error -> Error
                end
            catch
                _:_ -> {error, <<"invalid_blob_key">>}
            end
    end.

valid_root(Root) ->
    byte_size(Root) > 0
        andalso byte_size(Root) =< ?MAX_PATH_BYTES
        andalso binary:match(Root, <<0>>) =:= nomatch.

valid_key(Key) ->
    byte_size(Key) > 0
        andalso byte_size(Key) =< ?MAX_KEY_BYTES
        andalso binary:match(Key, <<0>>) =:= nomatch
        andalso binary:match(Key, <<"\\">>) =:= nomatch
        andalso binary:match(Key, <<":">>) =:= nomatch
        andalso valid_segments(binary:split(Key, <<"/">>, [global])).

valid_segments([]) -> false;
valid_segments(Segments) ->
    lists:all(fun(Segment) ->
        Segment =/= <<>> andalso Segment =/= <<".">> andalso Segment =/= <<"..">>
    end, Segments).

valid_sha256(Value) when byte_size(Value) =:= 64 ->
    lists:all(fun(Byte) ->
        (Byte >= $0 andalso Byte =< $9) orelse
            (Byte >= $a andalso Byte =< $f)
    end, binary_to_list(Value));
valid_sha256(_Value) -> false.

droplast([_Last]) -> [];
droplast([Head | Rest]) -> [Head | droplast(Rest)].

ensure_parent_directories(Parent, []) -> {ok, Parent};
ensure_parent_directories(Parent, [Segment | Rest]) ->
    Next = filename:join(Parent, Segment),
    case ensure_real_directory(Next) of
        ok -> ensure_parent_directories(Next, Rest);
        Error -> Error
    end.

ensure_real_directory(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> ok;
        {ok, _Info} -> {error, <<"unsafe_blob_path">>};
        {error, enoent} ->
            case file:make_dir(Path) of
                ok -> verify_directory(Path);
                {error, eexist} -> verify_directory(Path);
                {error, enoent} ->
                    case filelib:ensure_dir(filename:join(Path, ".beamtrace")) of
                        ok -> verify_directory(Path);
                        {error, Reason} -> {error, reason_binary(Reason)}
                    end;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

verify_directory(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> ok;
        _ -> {error, <<"unsafe_blob_path">>}
    end.

put_valid(Target, Key, Payload) ->
    case file:read_link_info(Target) of
        {ok, #file_info{type = regular, size = Size}}
                when Size =< ?MAX_BLOB_BYTES -> compare_existing(Target, Key, Payload);
        {ok, _Info} -> {error, <<"unsafe_blob_path">>};
        {error, enoent} -> create_immutable(Target, Key, Payload);
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

compare_existing(Target, Key, Payload) ->
    case file:read_file(Target) of
        {ok, Payload} -> {ok, blob(Key, Payload)};
        {ok, _Different} -> {error, <<"blob_conflict">>};
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

create_immutable(Target, Key, Payload) ->
    Parent = filename:dirname(Target),
    Temporary = filename:join(
        Parent,
        ".beamtrace-tmp-" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))
    ),
    Result = case write_synced(Temporary, Payload) of
        ok ->
            case file:make_link(Temporary, Target) of
                ok -> {ok, blob(Key, Payload)};
                {error, eexist} -> compare_existing(Target, Key, Payload);
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        Error -> Error
    end,
    _ = file:delete(Temporary),
    Result.

write_synced(Path, Payload) ->
    case file:open(Path, [write, binary, raw, exclusive]) of
        {ok, Device} ->
            Result = case file:write(Device, Payload) of
                ok -> file:sync(Device);
                Error -> Error
            end,
            _ = file:close(Device),
            case Result of
                ok -> ok;
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

read_regular_blob(Target) ->
    case file:read_link_info(Target) of
        {ok, #file_info{type = regular, size = Size}}
                when Size > 0, Size =< ?MAX_BLOB_BYTES ->
            case file:read_file(Target) of
                {ok, Payload} when byte_size(Payload) =:= Size -> {ok, Payload};
                {ok, _Payload} -> {error, <<"blob_changed_during_read">>};
                {error, Reason} -> {error, reason_binary(Reason)}
            end;
        {ok, #file_info{type = regular}} -> {error, <<"invalid_blob_payload">>};
        {ok, _Info} -> {error, <<"unsafe_blob_path">>};
        {error, enoent} -> {error, <<"blob_not_found">>};
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

blob(Key, Payload) ->
    {blob, Key, hex(crypto:hash(sha256, Payload)), byte_size(Payload)}.

hex(Binary) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Binary]).

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
