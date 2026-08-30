%% SPDX-License-Identifier: Apache-2.0 OR MIT
-module(beamtrace_oidc_discovery_ffi).

-export([
    get_json/2,
    remember_provider/3,
    cached_jwks/2,
    refresh_jwks/2,
    cache_refreshed_jwks/2
]).

-define(CACHE_TABLE, beamtrace_oidc_discovery_cache).
-define(REQUEST_TIMEOUT_MS, 16000).
-define(WORKER_TIMEOUT_MS, 17000).

get_json(Url, MaximumBytes)
        when is_binary(Url), is_integer(MaximumBytes), MaximumBytes > 0,
             MaximumBytes =< 1048576 ->
    try
        {ok, _} = application:ensure_all_started(ssl),
        {ok, _} = application:ensure_all_started(inets),
        SslOptions = [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {depth, 6},
            {customize_hostname_check, [
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
            ]}
        ],
        HttpOptions = [
            {connect_timeout, 5000},
            {timeout, 15000},
            {autoredirect, false},
            {ssl, SslOptions}
        ],
        Request = {binary_to_list(Url), [{"accept", "application/json"}]},
        request_in_worker(Request, HttpOptions, MaximumBytes)
    catch
        Class:CatchReason -> {error, reason_binary({Class, CatchReason})}
    end;
get_json(_Url, _MaximumBytes) -> {error, <<"invalid_request">>}.

request_in_worker(Request, HttpOptions, MaximumBytes) ->
    Parent = self(),
    Reference = make_ref(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        Parent ! {Reference, request_json(Request, HttpOptions, MaximumBytes)}
    end),
    receive
        {Reference, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Worker, Reason} ->
            {error, reason_binary(Reason)}
    after ?WORKER_TIMEOUT_MS ->
        exit(Worker, kill),
        receive
            {'DOWN', Monitor, process, Worker, _Reason} -> ok
        after 100 -> ok
        end,
        {error, <<"timeout">>}
    end.

request_json(Request, HttpOptions, MaximumBytes) ->
    Options = [{sync, false}, {stream, {self, once}}],
    case httpc:request(get, Request, HttpOptions, Options) of
        {ok, RequestId} ->
            Deadline = monotonic_milliseconds() + ?REQUEST_TIMEOUT_MS,
            receive_response(RequestId, MaximumBytes, Deadline);
        {error, Reason} -> {error, reason_binary(Reason)}
    end.

receive_response(RequestId, MaximumBytes, Deadline) ->
    Timeout = remaining_timeout(Deadline),
    receive
        {http, {RequestId, stream_start, Headers, HandlerPid}} ->
            case content_length_exceeds(Headers, MaximumBytes) of
                true ->
                    cancel_request(RequestId),
                    {error, <<"response_too_large">>};
                false ->
                    Status = stream_status(Headers),
                    receive_stream(
                        RequestId,
                        HandlerPid,
                        Status,
                        MaximumBytes,
                        Deadline,
                        0,
                        []
                    )
            end;
        {http, {RequestId, {{_Version, Status, _Reason}, _Headers, Body}}}
                when is_binary(Body), byte_size(Body) =< MaximumBytes ->
            {ok, {Status, Body}};
        {http, {RequestId, {{_Version, _Status, _Reason}, _Headers, _Body}}} ->
            {error, <<"response_too_large">>};
        {http, {RequestId, {error, Reason}}} ->
            {error, reason_binary(Reason)}
    after Timeout ->
        cancel_request(RequestId),
        {error, <<"timeout">>}
    end.

receive_stream(
    RequestId,
    HandlerPid,
    Status,
    MaximumBytes,
    Deadline,
    ReceivedBytes,
    Chunks
) ->
    case request_next(HandlerPid) of
        ok ->
            Timeout = remaining_timeout(Deadline),
            receive
                {http, {RequestId, stream, Body}} when is_binary(Body) ->
                    TotalBytes = ReceivedBytes + byte_size(Body),
                    case TotalBytes =< MaximumBytes of
                        true ->
                            receive_stream(
                                RequestId,
                                HandlerPid,
                                Status,
                                MaximumBytes,
                                Deadline,
                                TotalBytes,
                                [Body | Chunks]
                            );
                        false ->
                            cancel_request(RequestId),
                            {error, <<"response_too_large">>}
                    end;
                {http, {RequestId, stream_end, _Headers}} ->
                    {ok, {Status, iolist_to_binary(lists:reverse(Chunks))}};
                {http, {RequestId, {error, Reason}}} ->
                    {error, reason_binary(Reason)}
            after Timeout ->
                cancel_request(RequestId),
                {error, <<"timeout">>}
            end;
        _ ->
            cancel_request(RequestId),
            {error, <<"stream_failed">>}
    end.

stream_status(Headers) ->
    case header_value("content-range", Headers) of
        undefined -> 200;
        _ -> 206
    end.

content_length_exceeds(Headers, MaximumBytes) ->
    case header_value("content-length", Headers) of
        undefined -> false;
        Value ->
            try list_to_integer(string:trim(header_value_list(Value))) > MaximumBytes
            catch
                _:_ -> false
            end
    end.

header_value(_Name, []) -> undefined;
header_value(Name, [{Key, Value} | Rest]) ->
    case string:lowercase(header_value_list(Key)) of
        Name -> Value;
        _ -> header_value(Name, Rest)
    end.

header_value_list(Value) when is_binary(Value) -> binary_to_list(Value);
header_value_list(Value) when is_list(Value) -> Value;
header_value_list(Value) when is_atom(Value) -> atom_to_list(Value);
header_value_list(_) -> "".

remaining_timeout(Deadline) ->
    case Deadline - monotonic_milliseconds() of
        Remaining when Remaining > 0 -> Remaining;
        _ -> 0
    end.

monotonic_milliseconds() -> erlang:monotonic_time(millisecond).

cancel_request(RequestId) ->
    try httpc:cancel_request(RequestId) of
        _ -> ok
    catch
        _:_ -> ok
    end.

request_next(HandlerPid) ->
    try httpc:stream_next(HandlerPid) of
        Result -> Result
    catch
        _:_ -> error
    end.

remember_provider(Issuer, JwksUri, Jwks)
        when is_binary(Issuer), is_binary(JwksUri), is_binary(Jwks) ->
    cache_provider(Issuer, JwksUri, Jwks),
    nil.

cached_jwks(Issuer, Fallback) when is_binary(Issuer), is_binary(Fallback) ->
    case cached_provider(Issuer) of
        {Issuer, _JwksUri, Jwks} -> Jwks;
        _ -> Fallback
    end.

refresh_jwks(Issuer, MaximumBytes) when is_binary(Issuer) ->
    case cached_provider(Issuer) of
        {Issuer, JwksUri, _OldJwks} ->
            case get_json(JwksUri, MaximumBytes) of
                {ok, {200, Jwks}} -> {ok, Jwks};
                {ok, {Status, _}} ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("unexpected_status:~B", [Status])
                    )};
                Error -> Error
            end;
        _ -> {error, <<"offline_jwks">>}
    end.

cache_refreshed_jwks(Issuer, Jwks) when is_binary(Issuer), is_binary(Jwks) ->
    case cached_provider(Issuer) of
        {Issuer, JwksUri, _OldJwks} ->
            cache_provider(Issuer, JwksUri, Jwks);
        _ -> ok
    end,
    nil.

cached_provider(Issuer) ->
    ensure_cache_table(),
    try ets:lookup(?CACHE_TABLE, Issuer) of
        [{Issuer, JwksUri, Jwks}] -> {Issuer, JwksUri, Jwks};
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

cache_provider(Issuer, JwksUri, Jwks) ->
    ensure_cache_table(),
    try ets:insert(?CACHE_TABLE, {Issuer, JwksUri, Jwks}) of
        true -> ok
    catch
        error:badarg ->
            ensure_cache_table(),
            true = ets:insert(?CACHE_TABLE, {Issuer, JwksUri, Jwks}),
            ok
    end.

ensure_cache_table() ->
    case ets:whereis(?CACHE_TABLE) of
        undefined -> start_cache_owner();
        _Table -> ok
    end.

start_cache_owner() ->
    Parent = self(),
    Reference = make_ref(),
    _ = spawn(fun() ->
        try ets:new(?CACHE_TABLE, [
            named_table,
            public,
            set,
            {read_concurrency, true},
            {write_concurrency, true}
        ]) of
            _Table ->
                Parent ! {Reference, ready},
                cache_owner_loop()
        catch
            error:badarg -> Parent ! {Reference, ready}
        end
    end),
    receive
        {Reference, ready} -> ok
    after 5000 ->
        erlang:error(cache_start_timeout)
    end.

cache_owner_loop() ->
    receive
        _Message -> cache_owner_loop()
    end.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
